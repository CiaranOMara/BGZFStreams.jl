# BGZFStream
# ==========

# Read mode (.mode = READ_MODE)
# -----------------------------
#          compressed block          decompressed block
#          +---------------+         +---------------+
# .io ---> |xxxxxxx        | ------> |xxxxxxxxxxx    | --->
#     read +---------------+ inflate +---------------+ read
#                                    |------>| block_offset(.offset) ∈ [0, 64K)
#                                    |<-------->| .size ∈ [0, 64K)
#
# Write mode (.mode = WRITE_MODE)
# -------------------------------
#          compressed block          decompressed block
#          +---------------+         +---------------+
# .io <--- |xxxxxxx        | <------ |xxxxxxxx       | <---
#    write +---------------+ deflate +---------------+ write
#                                    |------>| block_offset(.offset) ∈ [0, 64K)
#                                    |<------------>| .size = 64K - 256
# - xxx: used data
# - 64K: 65536 (= BGZF_MAX_BLOCK_SIZE = 64 * 1024)

type Block
    # space for the compressed block
    compressed_block::Vector{UInt8}

    # space for the decompressed block
    decompressed_block::Vector{UInt8}

    # virtual file offset
    offset::VirtualOffset

    # number of available bytes in the decompressed block
    size::UInt

    # zstream object
    zstream::Libz.ZStream
end

function Block(mode)
    compressed_block = Vector{UInt8}(BGZF_MAX_BLOCK_SIZE)
    decompressed_block = Vector{UInt8}(BGZF_MAX_BLOCK_SIZE)
    offset = VirtualOffset(0, 0)

    if mode == READ_MODE
        zstream = Libz.init_inflate_zstream(true)
        size = 0
    else
        zstream = Libz.init_deflate_zstream(
            true,
            Libz.Z_DEFAULT_COMPRESSION,
            8,  # default memory level
            Libz.Z_DEFAULT_STRATEGY)
        size = BGZF_SAFE_BLOCK_SIZE
    end

    return Block(
        compressed_block,
        decompressed_block,
        offset,
        size,
        zstream)
end

# Stream type for the BGZF compression format.
type BGZFStream{T<:IO} <: IO
    # underlying IO stream
    io::T

    # read/write mode
    mode::UInt8

    # compressed & decompressed blocks with metadata and zstream
    blocks::Vector{Block}

    # current block index
    block_index::Int

    # whether stream is open
    isopen::Bool

    # callback function called when closing the stream
    onclose::Function
end

# BGZF blocks are no larger than 64 KiB before and after compression.
const BGZF_MAX_BLOCK_SIZE = UInt(64 * 1024)

# BGZF_MAX_BLOCK_SIZE minus "margin for safety"
# NOTE: Data block will become slightly larger after deflation when bytes are
# randomly distributed.
const BGZF_SAFE_BLOCK_SIZE = UInt(BGZF_MAX_BLOCK_SIZE - 256)

# Read mode:  inflate and read a BGZF file
# Write mode: deflate and write a BGZF file
const READ_MODE  = 0x00
const WRITE_MODE = 0x01

"""
    BGZFStream(io::IO[, mode::AbstractString="r"])
    BGZFStream(filename::AbstractString[, mode::AbstractString="r"])

Create an IO stream for the BGZF compression format.

The first argument is either an `IO` object or a filename. If `mode` is `"r"`
(read) the BGZF stream will be in read mode and decompress the underlying BGZF
blocks while reading. In read mode, `BGZFStream` supports the `seek` operation
using a virtual file offset (see `VirtualOffset`). If `mode` is `"w"` (write)
or `"a"` (append) the BGZF stream will be in write mode and compress written
data to BGZF blocks.
"""
function BGZFStream(io::IO, mode::AbstractString="r")
    if mode ∉ ("r", "w", "a")
        throw(ArgumentError("invalid mode: \"", mode, "\""))
    end

    # the number of parallel workers
    mode′ = mode == "r" ? READ_MODE : WRITE_MODE
    if mode′ == READ_MODE
        blocks = [Block(mode′) for _ in 1:nthreads()]
    else
        # Write mode is not (yet?) multi-threaded.
        blocks = [Block(mode′)]
    end
    stream = BGZFStream(io, mode′, blocks, 1, true, io -> close(io))

    if stream.mode == READ_MODE
        ensure_buffered_data(stream)
    end

    return stream
end

function BGZFStream(filename::AbstractString, mode::AbstractString="r")
    if mode ∉ ("r", "w", "a")
        throw(ArgumentError("invalid mode: '", mode, "'"))
    end
    return BGZFStream(open(filename, mode), mode)
end

"""
    virtualoffset(stream::BGZFStream)

Return the current virtual file offset of `stream`.
"""
function virtualoffset(stream::BGZFStream)
    return stream.blocks[stream.block_index].offset
end

function Base.show(io::IO, stream::BGZFStream)
    print(io,
        summary(stream),
        "(<",
        "mode=", stream.mode == READ_MODE ? "\"read\", " : "\"write\", ",
        ">)")
end

function Base.isopen(stream::BGZFStream)
    return stream.isopen
end

function Base.close(stream::BGZFStream)
    if stream.mode == WRITE_MODE
        if block_offset(stream.blocks[1].offset) > 0
            write_blocks!(stream)
        end
        write(stream.io, EOF_BLOCK)
    end
    for block in stream.blocks
        end_zstream(block.zstream, stream.mode)
    end
    stream.isopen = false
    stream.onclose(stream.io)
    return
end

function Base.flush(stream::BGZFStream)
    if stream.mode == WRITE_MODE
        flush(stream.io)
    end
    return
end

function Base.eof(stream::BGZFStream)
    if stream.mode == READ_MODE
        return ensure_buffered_data(stream) == 0
    else
        return true
    end
end

function Base.seek(stream::BGZFStream, voffset::VirtualOffset)
    if stream.mode == WRITE_MODE
        throw(ArgumentError("BGZFStream in write mode is not seekable"))
    end
    seek(stream.io, file_offset(voffset))
    read_blocks!(stream)
    block = first(stream.blocks)
    if block_offset(voffset) ≥ block.size
        throw(ArgumentError("too large in-block offset"))
    end
    block.offset = voffset
    return
end

function Base.read(stream::BGZFStream, ::Type{UInt8})
    if !isopen(stream)
        throw(ArgumentError("stream is already closed"))
    elseif stream.mode != READ_MODE
        throw(ArgumentError("stream is not readable"))
    end
    i = ensure_buffered_data(stream)
    if i == 0
        throw(EOFError())
    end
    block = stream.blocks[i]
    x = block_offset(block.offset += 1)
    byte = block.decompressed_block[x]
    if x == block.size
        ensure_buffered_data(stream)
    end
    return byte
end

function Base.write(stream::BGZFStream, byte::UInt8)
    if !isopen(stream)
        throw(ArgumentError("stream is already closed"))
    elseif stream.mode != WRITE_MODE
        throw(ArgumentError("stream is not writable"))
    end
    block = stream.blocks[1]
    x = block_offset(block.offset += 1)
    block.decompressed_block[x] = byte
    if x == block.size
        ensure_buffer_room(stream)
    end
    return 1
end

function Base.unsafe_read(stream::BGZFStream, p::Ptr{UInt8}, n::UInt)
    if !isopen(stream)
        throw(ArgumentError("stream is already closed"))
    elseif stream.mode != READ_MODE
        throw(ArgumentError("stream is not readable"))
    end
    p_end = p + n
    while p < p_end
        i = ensure_buffered_data(stream)
        if i == 0
            throw(EOFError())
        end
        block = stream.blocks[i]
        x = block_offset(block.offset)
        @assert x < block.size
        len = min(p_end - p, block.size - x)
        src = pointer(block.decompressed_block, x + 1)
        memcpy(p, src, len)
        block.offset += len
        p += len
    end
end

function Base.unsafe_write(stream::BGZFStream, p::Ptr{UInt8}, n::UInt)
    if !isopen(stream)
        throw(ArgumentError("stream is already closed"))
    elseif stream.mode != WRITE_MODE
        throw(ArgumentError("stream is not writable"))
    end
    block = stream.blocks[1]
    p_end = p + n
    while p < p_end
        x = block_offset(block.offset)
        len = min(p_end - p, block.size - x)
        dst = pointer(block.decompressed_block, x + 1)
        memcpy(dst, p, len)
        x = block_offset(block.offset += len)
        if x == block.size
            ensure_buffer_room(stream)
        end
        p += len
    end
    return Int(n)
end


# Internal functions
# ------------------

# Ensure buffered data (at least 1 byte) for reading.
@inline function ensure_buffered_data(stream)::Int
    #@assert stream.mode == READ_MODE
    @label doit
    while stream.block_index ≤ endof(stream.blocks)
        block = stream.blocks[stream.block_index]
        if block_offset(block.offset) != block.size
            return stream.block_index
        end
        stream.block_index += 1
    end
    if !eof(stream.io)
        read_blocks!(stream)
        @goto doit
    end
    return 0
end

# Ensure buffer room (at least 1 byte) for writing.
function ensure_buffer_room(stream)
    @assert stream.mode == WRITE_MODE
    for i in eachindex(stream.blocks)
        block = stream.blocks[i]
        if block_offset(block.offset) != block.size
            return i
        end
    end
    write_blocks!(stream)
    return 1
end

# A wrapper of memcpy.
function memcpy(dst, src, len)
    ccall(
        :memcpy,
        Ptr{Void},
        (Ptr{Void}, Ptr{Void}, Csize_t),
        dst, src, len)
end

immutable BGZFDataError <: Exception
    message::AbstractString
end

# Throw a BGZFDataError exception with the given error message.
function bgzferror(message::AbstractString="malformed BGZF data")
    throw(BGZFDataError(message))
end

# Read and inflate blocks.
function read_blocks!(stream)
    @assert stream.mode == READ_MODE

    # read BGZF blocks in sequence
    n_blocks = 0
    while n_blocks < length(stream.blocks) && !eof(stream.io)
        block = stream.blocks[n_blocks += 1]
        block.offset = VirtualOffset(position(stream.io), 0)
        bsize = read_bgzf_block!(stream.io, block.compressed_block)
        zstream = block.zstream
        zstream.next_in = pointer(block.compressed_block)
        zstream.avail_in = bsize
        zstream.next_out = pointer(block.decompressed_block)
        zstream.avail_out = BGZF_MAX_BLOCK_SIZE
    end

    # inflate blocks in parallel
    @threads for i in 1:n_blocks
        block = stream.blocks[i]
        zstream = block.zstream
        old_avail_out = zstream.avail_out
        ret = ccall(
            (:inflate, Libz._zlib),
            Cint,
            (Ref{Libz.ZStream}, Cint),
            zstream, Libz.Z_FINISH)
        # FIXME: check ret value
        block.size = old_avail_out - zstream.avail_out
    end

    for i in 1:n_blocks
        block = stream.blocks[i]
        # the decompresed block size must be strictly smaller than 64KiB
        @assert block.size < BGZF_MAX_BLOCK_SIZE
        reset_zstream(block.zstream, stream.mode)
    end

    stream.block_index = 1
    return
end

# Read a BGZF block from `input`.
function read_bgzf_block!(input, block)
    # TODO: check the number of read bytes

    # +---+---+---+---+---+---+---+---+---+---+
    # |ID1|ID2|CM |FLG|     MTIME     |XFL|OS | (more-->)
    # +---+---+---+---+---+---+---+---+---+---+
    unsafe_read(input, pointer(block), 10)
    id1_ok = block[1] == 0x1f
    id2_ok = block[2] == 0x8b
    cm_ok  = block[3] == 0x08
    flg_ok = block[4] == 0x04
    if !id1_ok || !id2_ok
        bgzferror("invalid gzip identifier")
    elseif !cm_ok
        bgzferror("invalid compression method")
    elseif !flg_ok
        bgzferror("invalid flag")
    end

    # +---+---+=================================+
    # | XLEN  |...XLEN bytes of "extra field"...| (more-->)
    # +---+---+=================================+
    unsafe_read(input, pointer(block, 11) , 2)
    xlen = UInt16(block[11]) | UInt16(block[12]) << 8
    unsafe_read(input, pointer(block, 13), xlen)
    bsize::Int = 0
    pos = 12
    while pos < 12 + xlen
        si1 = block[pos+1]
        si2 = block[pos+2]
        slen = UInt16(block[pos+3]) | UInt16(block[pos+4]) << 8
        if si1 == 0x42 || si2 == 0x43
            if slen != 2
                bgzferror("invalid subfield length")
            end
            bsize = (UInt16(block[pos+5]) | UInt16(block[pos+6]) << 8) + 1
        end
        # skip this field
        pos += 4 + slen
    end
    if bsize == 0
        bgzferror("no block size")
    end

    # +=======================+---+---+---+---+---+---+---+---+
    # |...compressed blocks...|     CRC32     |     ISIZE     |
    # +=======================+---+---+---+---+---+---+---+---+
    size = bsize - 1 - xlen - 19 + 8
    unsafe_read(input, pointer(block, 13 + xlen), size)

    if eof(input) && !is_eof_block(block)
        bgzferror("no end-of-file marker (maybe a truncated file)")
    end

    return bsize
end

function write_blocks!(stream)
    @assert stream.mode == WRITE_MODE

    n_blocks = length(stream.blocks)
    @assert n_blocks == 1

    for i in 1:n_blocks
        block = stream.blocks[i]
        zstream = block.zstream
        zstream.next_in = pointer(block.decompressed_block)
        zstream.avail_in = block_offset(block.offset)
        zstream.next_out = pointer(block.compressed_block, 9)
        zstream.avail_out = BGZF_MAX_BLOCK_SIZE - 8

        ret = ccall(
            (:deflate, Libz._zlib),
            Cint,
            (Ref{Libz.ZStream}, Cint),
            zstream, Libz.Z_FINISH)
        if ret != Libz.Z_STREAM_END
            if ret == Libz.Z_OK
                error("block size may exceed BGZF_MAX_BLOCK_SIZE")
            else
                error("failed to compress a BGZF block (zlib error $(ret))")
            end
        end

        blocksize = (BGZF_MAX_BLOCK_SIZE - 8) - zstream.avail_out + 8
        fix_header!(block.compressed_block, blocksize)
        nb = unsafe_write(stream.io, pointer(block.compressed_block), blocksize)
        if nb != blocksize
            error("failed to write a BGZF block")
        end
        block.offset = VirtualOffset(position(stream.io), 0)

        reset_zstream(zstream, WRITE_MODE)
    end
end

function write_block(stream)
    @assert stream.mode == WRITE_MODE

    zstream = stream.zstream
    zstream.next_in = pointer(stream.decompressed_block)
    zstream.avail_in = block_offset(stream.offset)
    zstream.next_out = pointer(stream.compressed_block, 9)
    zstream.avail_out = BGZF_MAX_BLOCK_SIZE - 8

    ret = ccall(
        (:deflate, Libz._zlib),
        Cint,
        (Ref{Libz.ZStream}, Cint),
        zstream, Libz.Z_FINISH)
    if ret != Libz.Z_STREAM_END
        if ret == Libz.Z_OK
            error("block size may exceed BGZF_MAX_BLOCK_SIZE")
        else
            error("failed to compress a BGZF block (zlib error $(ret))")
        end
    end

    blocksize = (BGZF_MAX_BLOCK_SIZE - 8) - zstream.avail_out + 8
    fix_header!(stream.compressed_block, blocksize)
    write(stream.io, view(stream.compressed_block, 1:Int(blocksize)))
    stream.offset = VirtualOffset(position(stream.io), 0)

    reset_zstream(stream)
end

function fix_header!(block, blocksize)
    copy!(block,
          # ID1   ID2    CM   FLG  |<--     MTIME    -->|   XFL    OS
          [0x1f, 0x8b, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
    copy!(block, 11,
          #  XLEN    S1    S2    SLEN          BSIZE
          reinterpret(UInt8, [0x0006, 0x4342, 0x0002, UInt16(blocksize - 1)]))
end

# end-of-file marker block (used for detecting unintended file truncation)
const EOF_BLOCK = [
    0x1f, 0x8b, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00,
    0x00, 0xff, 0x06, 0x00, 0x42, 0x43, 0x02, 0x00,
    0x1b, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00
]

# Return true iff the block is a end-of-file marker.
function is_eof_block(block)
    if length(block) < length(EOF_BLOCK)
        return false
    end
    for i in 1:endof(EOF_BLOCK)
        if block[i] != EOF_BLOCK[i]
            return false
        end
    end
    return true
end

# Reset the zstream.
function reset_zstream(zstream, mode)
    if mode == READ_MODE
        ret = ccall(
            (:inflateReset, Libz._zlib),
            Cint,
            (Ref{Libz.ZStream},),
            zstream)
    else
        ret = ccall(
            (:deflateReset, Libz._zlib),
            Cint,
            (Ref{Libz.ZStream},),
            zstream)
    end
    if ret != Libz.Z_OK
        error("failed to reset zlib stream")
    end
end

# End the zstream.
function end_zstream(zstream, mode)
    if mode == READ_MODE
        ret = ccall(
            (:inflateEnd, Libz._zlib),
            Cint,
            (Ref{Libz.ZStream},),
            zstream)
    else
        ret = ccall(
            (:deflateEnd, Libz._zlib),
            Cint,
            (Ref{Libz.ZStream},),
            zstream)
    end
    if ret != Libz.Z_OK
        error("failed to end zlib stream")
    end
end
