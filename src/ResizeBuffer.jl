module ResizeBufferImpl


import Bumper:
    alloc_ptr!,
    checkpoint_save,
    checkpoint_restore!,
    default_buffer,
    reset_buffer!,
    with_buffer
import Bumper.Internals: malloc, free

const default_max_size = 1_048_576

"""
    ResizeBuffer{StorageType}

This is a simple bump allocator that could be used to store a fixed amount of memory of type
`StorageType`, so long as `::StorageType` supports `pointer`, and `sizeof`.

Do not manually manipulate the fields of a `ResizeBuffer` that is in use.
"""
mutable struct ResizeBuffer
    buf::Ptr{Cvoid}
    buf_len::UInt

    offset::UInt
    max_offset::UInt

    overflow::Vector{Ptr{Cvoid}}

    function ResizeBuffer(max_size::Int = default_max_size; finalize::Bool = true)
        buf = malloc(max_size)
        buf_len = max_size
        overflow = Ptr{Cvoid}[]
        resizebuf = new(buf, buf_len, UInt(0), UInt(0), overflow)
        finalize && finalizer(free, resizebuf)
        return resizebuf
    end
end

function free(buf::ResizeBuffer)
    foreach(free, buf.overflow)
    free(buf.buf)
    return nothing
end

const default_buffer_key = gensym(:buffer)


"""
    default_buffer(::Type{ResizeBuffer}) -> ResizeBuffer

Return the current task-local default `ResizeBuffer`, if one does not exist in the current task,
it will create one automatically.
"""
function default_buffer(::Type{ResizeBuffer})
    return get!(() -> ResizeBuffer(), task_local_storage(), default_buffer_key)::ResizeBuffer
end

function alloc_ptr!(b::ResizeBuffer, sz::Int)::Ptr{Cvoid}
    old_offset = b.offset
    b.offset += sz
    b.max_offset = max(b.max_offset, b.offset)

    # grow the buffer - only available if empty
    if iszero(old_offset) & (b.max_offset > b.buf_len)
        free(b.buf)
        b.buf = malloc(b.max_offset)
        b.buf_len = b.max_offset
    end

    if b.offset ≤ b.buf_len     # use the buffer if there is enough space
        ptr = b.buf + old_offset
    else                        # manually allocate if not
        ptr = malloc(sz)
        push!(b.overflow, ptr)
    end

    return ptr
end

function reset_buffer!(b::ResizeBuffer)
    b.offset = UInt(0)
    b.max_offset = UInt(0) # do we want this?

    foreach(free, b.overflow)
    resize!(b.overflow, 0)

    return b
end

struct ResizeCheckpoint
    buf::ResizeBuffer
    offset::UInt
    overflow_length::Int
end

checkpoint_save(buf::ResizeBuffer) = ResizeCheckpoint(buf, buf.offset, length(buf.overflow))
function checkpoint_restore!(cp::ResizeCheckpoint)
    # restore overflow
    foreach(free, @view cp.buf.overflow[(cp.overflow_length + 1):end])
    resize!(cp.buf.overflow, cp.overflow_length)

    # restore offset
    cp.buf.offset = cp.offset

    return nothing
end

with_buffer(f, b::ResizeBuffer) = task_local_storage(f, default_buffer_key, b)

end # module ResizeBufferImpl
