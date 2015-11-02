(*
 * Copyright (C) 2015 David Scott <dave@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)
open Sexplib.Std
open Result
open Error
open Offset

let round_up x size = Int64.(mul (div (add x (pred size)) size) size)

let ( <| ) = Int64.shift_left
let ( |> ) = Int64.shift_right_logical

module Make(B: S.RESIZABLE_BLOCK) = struct

  type 'a io = 'a Lwt.t
  type error = B.error
  type info = {
    read_write : bool;
    sector_size : int;
    size_sectors : int64;
  }

  type id = B.id
  type page_aligned_buffer = B.page_aligned_buffer
  type t = {
    h: Header.t;
    base: B.t;
    base_info: B.info;
    info: info;
    mutable next_cluster: int64;
  }

  let get_info t = Lwt.return t.info

  let (>>*=) m f =
    let open Lwt in
    m >>= function
    | `Error x -> Lwt.return (`Error x)
    | `Ok x -> f x

  let rec iter f = function
    | [] -> Lwt.return (`Ok ())
    | x :: xs ->
        f x >>*= fun () ->
        iter f xs

  (* Take an offset and round it down to the nearest physical sector, returning
     the sector number and an offset within the sector *)
  let rec to_sector t = function
    | Bytes x ->
      Int64.(div x (of_int t.base_info.B.sector_size)),
      Int64.(to_int (rem x (of_int t.base_info.B.sector_size)))
    | PhysicalSectors x -> x, 0
    | Clusters x ->
      let bytes = x <| (Int32.to_int t.h.Header.cluster_bits) in
      to_sector t (Bytes bytes)

  let to_bytes t = function
    | Bytes x -> x
    | PhysicalSectors x -> Int64.(mul (of_int t.base_info.B.sector_size) x)
    | Clusters x -> x <| (Int32.to_int t.h.Header.cluster_bits)

  (* Return data at [offset] in the underlying block device, up to the sector
     boundary. This is useful for fields which don't cross boundaries *)
  let read_field t offset =
    let sector, within = to_sector t offset in
    let buf = Cstruct.sub Io_page.(to_cstruct (get 1)) 0 t.base_info.B.sector_size in
    B.read t.base sector [ buf ]
    >>*= fun () ->
    Lwt.return (`Ok (Cstruct.shift buf within))

  (** Read-modify-write data at [offset] in the underying block device, up
      to the sector boundary. This is useful for fields which don't cross
      boundaries *)
  let update_field t offset f =
    let sector, within = to_sector t offset in
    let buf = Cstruct.sub Io_page.(to_cstruct (get 1)) 0 t.base_info.B.sector_size in
    B.read t.base sector [ buf ]
    >>*= fun () ->
    f (Cstruct.shift buf within);
    B.write t.base sector [ buf ]

  let resize t new_size =
    let sector, within = to_sector t new_size in
    if within <> 0
    then Lwt.return (`Error (`Unknown (Printf.sprintf "Internal error: attempting to resize to a non-sector multiple %s" (Offset.to_string new_size))))
    else B.resize t.base sector

  type offset = {
    offset: int64;
    copied: bool; (* refcount = 1 implies no snapshots implies direct write ok *)
    compressed: bool;
  }

  (* L1 and L2 entries have a "copied" bit which, if set, means that
     the block isn't shared and therefore can be written to directly *)
  let get_copied x = x |> 63 = 1L

  let set_copied x = Int64.logor x (1L <| 63)

  (* L2 entries can be marked as compressed *)
  let get_compressed x = (x <| 1) |> 63 = 1L

  let set_compressed x = Int64.logor x (1L <| 62)

  let parse_offset buf =
    let raw = Cstruct.BE.get_uint64 buf 0 in
    let copied = raw |> 63 = 1L in
    let compressed = (raw <| 1) |> 63 = 1L in
    let offset = (raw <| 2) |> 2 in
    { offset; copied; compressed }

  module Cluster = struct

    let malloc t =
      let cluster_bits = Int32.to_int t.Header.cluster_bits in
      let npages = max 1 (cluster_bits lsl (cluster_bits - 12)) in
      let pages = Io_page.(to_cstruct (get npages)) in
      Cstruct.sub pages 0 (1 lsl cluster_bits)

    (** Allocate a cluster, resize the underlying device and return the
        byte offset of the new cluster, suitable for writing to one of
        the various metadata tables. *)
    let extend t =
      let cluster = t.next_cluster in
      t.next_cluster <- Int64.succ t.next_cluster;
      resize t (Clusters t.next_cluster)
      >>*= fun () ->
      Lwt.return (`Ok (to_bytes t (Clusters cluster)))

    (* The number of 16-bit reference counts per cluster *)
    let refcounts_per_cluster t =
      let cluster_bits = Int32.to_int t.Header.cluster_bits in
      let size = t.Header.size in
      let cluster_size = 1L <| cluster_bits in
      (* Each reference count is 2 bytes long *)
      Int64.div cluster_size 2L

    (* Compute the maximum size of the refcount table, if we need it *)
    let max_refount_table_size t =
      let cluster_bits = Int32.to_int t.h.Header.cluster_bits in
      let size = t.h.Header.size in
      let cluster_size = 1L <| cluster_bits in
      let refs_per_cluster = refcounts_per_cluster t.h in
      let size_in_clusters = Int64.div (round_up size cluster_size) cluster_size in
      let refs_clusters_required = Int64.div (round_up size_in_clusters refs_per_cluster) refs_per_cluster in
      (* Each cluster containing references consumes 8 bytes in the
         refcount_table. How much space is that? *)
      let refcount_table_bytes = Int64.mul refs_clusters_required 8L in
      Int64.div (round_up refcount_table_bytes cluster_size) cluster_size

    (** Increment the refcount of a given cluster. Note this might need
        to allocate itself, to enlarge the refcount table. *)
    let incr_refcount t cluster =
      let cluster_bits = Int32.to_int t.h.Header.cluster_bits in
      let size = t.h.Header.size in
      let cluster_size = 1L <| cluster_bits in
      let index_in_cluster = Int64.(to_int (div cluster (refcounts_per_cluster t.h))) in
      let within_cluster = Int64.(to_int (rem cluster (refcounts_per_cluster t.h))) in
      if index_in_cluster > 0
      then Lwt.return (`Error (`Unknown "I don't know how to enlarge a refcount table yet"))
      else begin
        let cluster = malloc t.h in
        let refcount_table_sector = Int64.(div t.h.Header.refcount_table_offset (of_int t.base_info.B.sector_size)) in
        B.read t.base refcount_table_sector [ cluster ]
        >>*= fun () ->
        let offset = Cstruct.BE.get_uint64 cluster (8 * index_in_cluster) in
        if offset = 0L then begin
          extend t
          >>*= fun offset ->
          let cluster' = malloc t.h in
          Cstruct.memset cluster' 0;
          Cstruct.BE.set_uint16 cluster' (2 * within_cluster) 1;
          let sector = Int64.(div offset (of_int t.base_info.B.sector_size)) in
          B.write t.base sector [ cluster' ]
          >>*= fun () ->
          Cstruct.BE.set_uint64 cluster (8 * index_in_cluster) offset;
          B.write t.base refcount_table_sector [ cluster ]
          >>*= fun () ->
          (* recursively increment refcunt of offset? *)
          Lwt.return (`Ok ())
        end else begin
          let sector = Int64.(div offset (of_int t.base_info.B.sector_size)) in
          B.read t.base sector [ cluster ]
          >>*= fun () ->
          let count = Cstruct.BE.get_uint16 cluster (2 * within_cluster) in
          Cstruct.BE.set_uint16 cluster (2 * within_cluster) (count + 1);
          B.write t.base sector [ cluster ]
        end
      end

    (* Walk the L1 and L2 tables to translate an address *)
    let walk ?(allocate=false) t a =
      let table_offset = t.h.Header.l1_table_offset in
      (* Read l1[l1_index] as a 64-bit offset *)
      let l1_index_offset = Bytes (Int64.(add t.h.Header.l1_table_offset (mul 8L a.Address.l1_index)))in
      read_field t l1_index_offset
      >>*= fun buf ->
      let l2_table_offset = Cstruct.BE.get_uint64 buf 0 in

      let (>>|=) m f =
        let open Lwt in
        m >>= function
        | `Error x -> Lwt.return (`Error x)
        | `Ok None -> Lwt.return (`Ok None)
        | `Ok (Some x) -> f x in

      (* Look up an L2 table *)
      ( if l2_table_offset = 0L then begin
          if not allocate then begin
            Lwt.return (`Ok None)
          end else begin
            extend t
            >>*= fun offset ->
            let cluster = Int64.div offset (1L <| (Int32.to_int t.h.Header.cluster_bits)) in
            incr_refcount t cluster
            >>*= fun () ->
            update_field t l1_index_offset
              (fun buf -> Cstruct.BE.set_uint64 buf 0 (set_copied offset))
            >>*= fun () ->
            Lwt.return (`Ok (Some offset))
          end
        end else begin
          let compressed = get_compressed l2_table_offset in
          if compressed then failwith "compressed";
          (* mask off the copied and compressed bits *)
          let l2_table_offset = (l2_table_offset <| 2) |> 2 in
          Lwt.return (`Ok (Some l2_table_offset))
        end
      ) >>|= fun l2_table_offset ->

      (* Look up a cluster *)
      let l2_index_offset = Bytes (Int64.(add l2_table_offset (mul 8L a.Address.l2_index))) in
      read_field t l2_index_offset
      >>*= fun buf ->
      let cluster_offset = Cstruct.BE.get_uint64 buf 0 in
      ( if cluster_offset = 0L then begin
          if not allocate then begin
            Lwt.return (`Ok None)
          end else begin
            extend t
            >>*= fun offset ->
            let cluster = Int64.div offset (1L <| (Int32.to_int t.h.Header.cluster_bits)) in
            incr_refcount t cluster
            >>*= fun () ->
            update_field t l2_index_offset
              (fun buf -> Cstruct.BE.set_uint64 buf 0 (set_copied offset))
            >>*= fun () ->
            Lwt.return (`Ok (Some offset))
          end
        end else begin
          let compressed = get_compressed cluster_offset in
          if compressed then failwith "compressed";
          (* mask off the copied and compressed bits *)
          let cluster_offset = (cluster_offset <| 2) |> 2 in
          Lwt.return (`Ok (Some cluster_offset))
        end
      ) >>|= fun cluster_offset ->

      if cluster_offset = 0L
      then Lwt.return (`Ok None)
      else Lwt.return (`Ok (Some (Int64.add cluster_offset a.Address.cluster)))

  end

  (* Decompose into single sector reads *)
  let rec chop into ofs = function
    | [] -> []
    | buf :: bufs ->
      if Cstruct.len buf > into then begin
        let this = ofs, Cstruct.sub buf 0 into in
        let rest = chop into (Int64.succ ofs) (Cstruct.shift buf into :: bufs) in
        this :: rest
      end else begin
        (ofs, buf) :: (chop into (Int64.succ ofs) bufs)
      end

  let read t sector bufs =
    (* Inefficiently perform 3x physical I/Os for every 1 virtual I/O *)
    iter (fun (sector, buf) ->
      let offset = Int64.mul sector 512L in
      let address = Address.of_offset (Int32.to_int t.h.Header.cluster_bits) offset in
      Cluster.walk t address
      >>*= function
      | None ->
        Cstruct.memset buf 0;
        Lwt.return (`Ok ())
      | Some offset' ->
        let base_sector = Int64.(div offset' (of_int t.base_info.B.sector_size)) in
        B.read t.base base_sector [ buf ]
    ) (chop t.base_info.B.sector_size sector bufs)

  let write t sector bufs =
    (* Inefficiently perform 3x physical I/Os for every 1 virtual I/O *)
    iter (fun (sector, buf) ->
      let offset = Int64.mul sector 512L in
      let address = Address.of_offset (Int32.to_int t.h.Header.cluster_bits) offset in
      Cluster.walk ~allocate:true t address
      >>*= function
      | None ->
        Lwt.return (`Error (`Unknown "this should never happen"))
      | Some offset' ->
        let base_sector = Int64.(div offset' (of_int t.base_info.B.sector_size)) in
        B.write t.base base_sector [ buf ]
    ) (chop t.base_info.B.sector_size sector bufs)

  let disconnect t = B.disconnect t.base

  let make base h =
    let open Lwt in
    B.get_info base
    >>= fun base_info ->
    (* The virtual disk has 512 byte sectors *)
    let info' = {
      read_write = false;
      sector_size = 512;
      size_sectors = Int64.(div h.Header.size 512L);
    } in
    (* We assume the backing device is resized dynamically so the
       size is the address of the next cluster *)
    let size_bytes = Int64.(mul base_info.B.size_sectors (of_int base_info.B.sector_size)) in
    let next_cluster = Int64.(div size_bytes (1L <| (Int32.to_int h.Header.cluster_bits))) in
    Lwt.return (`Ok { h; base; info = info'; base_info; next_cluster })

  let connect base =
    let open Lwt in
    B.get_info base
    >>= fun base_info ->
    let sector = Cstruct.sub Io_page.(to_cstruct (get 1)) 0 base_info.B.sector_size in
    B.read base 0L [ sector ]
    >>= function
    | `Error x -> Lwt.return (`Error x)
    | `Ok () ->
      match Header.read sector with
      | Error (`Msg m) -> Lwt.return (`Error (`Unknown m))
      | Ok (h, _) -> make base h

  let create base size =
    let version = `Two in
    let backing_file_offset = 0L in
    let backing_file_size = 0l in
    let cluster_bits = 16 in
    let cluster_size = 1L <| cluster_bits in
    let crypt_method = `None in
    (* qemu-img places the refcount table next in the file and only
       qemu-img creates a tiny refcount table and grows it on demand *)
    let refcount_table_offset = cluster_size in
    let refcount_table_clusters = 1L in

    (* qemu-img places the L1 table after the refcount table *)
    let l1_table_offset = Int64.(mul (add 1L refcount_table_clusters) (1L <| cluster_bits)) in
    (* The L2 table is of size (1L <| cluster_bits) bytes
       and contains (1L <| (cluster_bits - 3)) 8-byte pointers.
       A single L2 table therefore manages
       (1L <| (cluster_bits - 3)) * (1L <| cluster_bits) bytes
       = (1L <| (2 * cluster_bits - 3)) bytes. *)
    let bytes_per_l2 = 1L <| (2 * cluster_bits - 3) in
    let l2_tables_required = Int64.div (round_up size bytes_per_l2) bytes_per_l2 in
    let nb_snapshots = 0l in
    let snapshots_offset = 0L in
    let h = {
      Header.version; backing_file_offset; backing_file_size;
      cluster_bits = Int32.of_int cluster_bits; size; crypt_method;
      l1_size = Int64.to_int32 l2_tables_required;
      l1_table_offset; refcount_table_offset;
      refcount_table_clusters = Int64.to_int32 refcount_table_clusters;
      nb_snapshots; snapshots_offset
    } in
    (* Resize the underlying device to contain the header + refcount table
       + l1 table. Future allocations will enlarge the file. *)
    let l1_size_bytes = Int64.mul 8L l2_tables_required in
    let next_free_byte = round_up (Int64.add l1_table_offset l1_size_bytes) cluster_size in
    let open Lwt in
    B.get_info base
    >>= fun base_info ->
    let size_sectors = Int64.(div next_free_byte (of_int base_info.B.sector_size)) in
    B.resize base size_sectors
    >>*= fun () ->

    let page = Io_page.(to_cstruct (get 1)) in
    match Header.write h page with
    | Result.Ok _ ->
      B.write base 0L [ page ]
      >>*= fun () ->
      make base h
      >>*= fun t ->
      (* Write an initial empty refcount table *)
      let cluster = Cluster.malloc t.h in
      Cstruct.memset cluster 0;
      B.write base Int64.(div refcount_table_offset (of_int t.base_info.B.sector_size)) [ cluster ]
      >>*= fun () ->
      Cluster.incr_refcount t 0L (* header *)
      >>*= fun () ->
      Cluster.incr_refcount t (Int64.div refcount_table_offset cluster_size)
      >>*= fun () ->
      (* Write an initial empty L1 table *)
      B.write base Int64.(div l1_table_offset (of_int t.base_info.B.sector_size)) [ cluster ]
      >>*= fun () ->
      Cluster.incr_refcount t (Int64.div l1_table_offset cluster_size)
      >>*= fun () ->
      Lwt.return (`Ok t)
    | Result.Error (`Msg m) ->
      Lwt.return (`Error (`Unknown m))
end
