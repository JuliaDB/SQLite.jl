module SQLite

using Random, Serialization
using WeakRefStrings, DBInterface

export DBInterface, SQLiteException

struct SQLiteException <: Exception
    msg::AbstractString
end

include("consts.jl")
include("api.jl")

const DBHandle = Ptr{Cvoid}   # SQLite3 DB connection handle
const StmtHandle = Ptr{Cvoid} # SQLite3 prepared statement handle

# Normal constructor from filename
sqliteexception(handle::DBHandle) = SQLiteException(unsafe_string(sqlite3_errmsg(handle)))
sqliteerror(handle::DBHandle) = throw(sqliteexception(handle))

"""
Internal wrapper that holds the handle to SQLite3 prepared statement.
It is managed by [`SQLite.DB`](@ref) and referenced by the "public" [`SQLite.Stmt`](@ref) object.

When no `SQLite.Stmt` instances reference the given `SQlite._Stmt` object,
it is closed automatically.

When `SQLite.DB` is closed or [`SQLite.finalize_statements!`](@ref) is called,
all its `SQLite._Stmt` objects are closed.
"""
mutable struct _Stmt
    handle::StmtHandle
    params::Dict{Int, Any}

    function _Stmt(handle::StmtHandle)
        stmt = new(handle, Dict{Int, Any}())
        finalizer(_close!, stmt)
        return stmt
    end
end

# close statement
function _close!(stmt::_Stmt)
    stmt.handle == C_NULL || sqlite3_finalize(stmt.handle)
    stmt.handle = C_NULL
    return
end

# _Stmt unique identifier in DB
const _StmtId = Int

"""
    `SQLite.DB()` => in-memory SQLite database
    `SQLite.DB(file)` => file-based SQLite database

Constructors for a representation of an sqlite database, either backed by an on-disk file or in-memory.

`SQLite.DB` requires the `file` string argument in the 2nd definition
as the name of either a pre-defined SQLite database to be opened,
or if the file doesn't exist, a database will be created.
Note that only sqlite 3.x version files are supported.

The `SQLite.DB` object represents a single connection to an SQLite database.
All other SQLite.jl functions take an `SQLite.DB` as the first argument as context.

To create an in-memory temporary database, call `SQLite.DB()`.

The `SQLite.DB` will be automatically closed/shutdown when it goes out of scope
(i.e. the end of the Julia session, end of a function call wherein it was created, etc.)
"""
mutable struct DB <: DBInterface.Connection
    file::String
    handle::DBHandle
    stmts::Dict{_StmtId, _Stmt} # opened prepared statements

    lastStmtId::_StmtId

    function DB(f::AbstractString)
        handle = Ref{DBHandle}()
        f = isempty(f) ? f : expanduser(f)
        if @OK sqlite3_open(f, handle)
            db = new(f, handle[], Dict{StmtHandle, _Stmt}(), 0)
            finalizer(_close, db)
            return db
        else # error
            sqliteerror(handle[])
        end
    end
end
DB() = DB(":memory:")
DBInterface.connect(::Type{DB}) = DB()
DBInterface.connect(::Type{DB}, f::AbstractString) = DB(f)
DBInterface.close!(db::DB) = _close(db)
Base.close(db::DB) = _close(db)
Base.isopen(db::DB) = db.handle != C_NULL

# close all prepared statements of db connection
function finalize_statements!(db::DB)
    for stmt in values(db.stmts)
        _close!(stmt)
    end
    empty!(db.stmts)
end

function _close(db::DB)
    finalize_statements!(db)
    # disconnect from DB
    db.handle == C_NULL || sqlite3_close_v2(db.handle)
    db.handle = C_NULL
    return
end

sqliteerror(db::DB) = sqliteerror(db.handle)
sqliteexception(db::DB) = sqliteexception(db.handle)

Base.show(io::IO, db::SQLite.DB) = print(io, string("SQLite.DB(", "\"$(db.file)\"", ")"))

# prepare given sql statement
function _Stmt(db::DB, sql::AbstractString)
    handle = Ref{StmtHandle}()
    sqliteprepare(db, sql, handle, Ref{StmtHandle}())
    return _Stmt(handle[])
end

"""
    SQLite.Stmt(db, sql) => SQL.Stmt

Prepares an optimized internal representation of SQL statement in
the context of the provided SQLite3 `db` and constructs the `SQLite.Stmt`
Julia object that holds a reference to the prepared statement.

*Note*: the `sql` statement is not actually executed, but only compiled
(mainly for usage where the same statement is executed multiple times
with different parameters bound as values).

Internally `SQLite.Stmt` constructor creates the [`SQLite._Stmt`](@ref) object that is managed by `db`.
`SQLite.Stmt` references the `SQLite._Stmt` by its unique id.

The `SQLite.Stmt` will be automatically closed/shutdown when it goes out of scope
(i.e. the end of the Julia session, end of a function call wherein it was created, etc.).
One can also call `DBInterface.close!(stmt)` to immediately close it.

All prepared statements of a given DB connection are also automatically closed when the
DB is disconnected or when [`SQLite.finalize_statements!`](@ref) is explicitly called.
"""
mutable struct Stmt <: DBInterface.Statement
    db::DB
    id::_StmtId # id of _Stmt inside db (may refer to already closed connection)

    function Stmt(db::DB, sql::AbstractString)
        _stmt = _Stmt(db, sql)
        id = (db.lastStmtId += 1)
        stmt = new(db, id)
        db.stmts[id] = _stmt # FIXME check for duplicate handle?
        finalizer(_finalize, stmt)
        return stmt
    end
end

# check if the statement is ready (not finalized due to
# _close(_Stmt) called and the statment handle removed from DB)
isready(stmt::Stmt) = haskey(stmt.db.stmts, stmt.id)

# get underlying _Stmt or nothing if not found
_stmt_safe(stmt::Stmt) = get(stmt.db.stmts, stmt.id, nothing)

# get underlying _Stmt or throw if not found
@inline function _stmt(stmt::Stmt)
    _st = _stmt_safe(stmt)
    (_st === nothing) && throw(SQLiteException("Statement $(stmt.id) not found"))
    return _st
end

# automatically finalizes prepared statement (_Stmt)
# when no Stmt objects refer to it and removes
# it from the db.stmts collection
_finalize(stmt::Stmt) = DBInterface.close!(stmt)

# explicitly close prepared statement
function DBInterface.close!(stmt::Stmt)
    _st = _stmt_safe(stmt)
    if _st !== nothing
        _close!(_st)
        delete!(stmt.db.stmts, stmt.id) # remove the _Stmt
    end
    return stmt
end

sqliteprepare(db::DB, sql::AbstractString, stmt::Ref{StmtHandle}, null::Ref{StmtHandle}) =
    @CHECK db sqlite3_prepare_v2(db.handle, sql, stmt, null)

include("UDF.jl")
export @sr_str

"""
    SQLite.clear!(stmt::SQLite.Stmt)

Clears any bound values to a prepared SQL statement
"""
function clear!(stmt::Stmt)
    _st = _stmt(stmt)
    sqlite3_clear_bindings(_st.handle)
    empty!(_st.params)
    return
end

"""
    SQLite.bind!(stmt::SQLite.Stmt, values)

bind `values` to parameters in a prepared [`SQLite.Stmt`](@ref). Values can be:

* `Vector` or `Tuple`: where each element will be bound to an SQL parameter by index order
* `Dict` or `NamedTuple`; where values will be bound to named SQL parameters by the `Dict`/`NamedTuple` key

Additional methods exist for working individual SQL parameters:

* `SQLite.bind!(stmt, name, val)`: bind a single value to a named SQL parameter
* `SQLite.bind!(stmt, index, val)`: bind a single value to a SQL parameter by index number

From the [SQLite documentation](https://www3.sqlite.org/cintro.html):

> Usually, though,
> it is not useful to evaluate exactly the same SQL statement more than once.
> More often, one wants to evaluate similar statements.
> For example, you might want to evaluate an INSERT statement
> multiple times though with different values to insert.
> To accommodate this kind of flexibility,
> SQLite allows SQL statements to contain parameters
> which are "bound" to values prior to being evaluated.
> These values can later be changed and the same prepared statement
> can be evaluated a second time using the new values.
>
> In SQLite,
> wherever it is valid to include a string literal,
> one can use a parameter in one of the following forms:
>
> - `?`
> - `?NNN`
> - `:AAA`
> - `\$AAA`
> - `@AAA`
>
> In the examples above,
> `NNN` is an integer value and `AAA` is an identifier.
> A parameter initially has a value of `NULL`.
> Prior to calling `sqlite3_step()` for the first time
> or immediately after `sqlite3_reset()``,
> the application can invoke one of the `sqlite3_bind()` interfaces
> to attach values to the parameters.
> Each call to `sqlite3_bind()` overrides prior bindings on the same parameter.

"""
function bind! end

function bind!(stmt::_Stmt, params::DBInterface.NamedStatementParams)
    nparams = sqlite3_bind_parameter_count(stmt.handle)
    (nparams <= length(params)) || throw(SQLiteException("values should be provided for all query placeholders"))
    for i in 1:nparams
        name = unsafe_string(sqlite3_bind_parameter_name(stmt.handle, i))
        isempty(name) && throw(SQLiteException("nameless parameters should be passed as a Vector"))
        # name is returned with the ':', '@' or '$' at the start
        sym = Symbol(name[2:end])
        haskey(params, sym) || throw(SQLiteException("`$name` not found in values keyword arguments to bind to sql statement"))
        bind!(stmt, i, params[sym])
    end
end

function bind!(stmt::_Stmt, values::DBInterface.PositionalStatementParams)
    nparams = sqlite3_bind_parameter_count(stmt.handle)
    (nparams == length(values)) || throw(SQLiteException("values should be provided for all query placeholders"))
    for i in 1:nparams
        @inbounds bind!(stmt, i, values[i])
    end
end

bind!(stmt::Stmt, values::DBInterface.StatementParams) = bind!(_stmt(stmt), values)

bind!(stmt::Union{_Stmt, Stmt}; kwargs...) = bind!(stmt, kwargs.data)

# Binding parameters to SQL statements
function bind!(stmt::_Stmt, name::AbstractString, val::Any)
    i::Int = sqlite3_bind_parameter_index(stmt.handle, name)
    if i == 0
        throw(SQLiteException("SQL parameter $name not found in $stmt"))
    end
    return bind!(stmt, i, val)
end

# binding method for internal _Stmt class
bind!(stmt::_Stmt, i::Integer, val::AbstractFloat)  = (stmt.params[i] = val; @CHECK stmt.db sqlite3_bind_double(stmt.handle, i, Float64(val)); return nothing)
bind!(stmt::_Stmt, i::Integer, val::Int32)          = (stmt.params[i] = val; @CHECK stmt.db sqlite3_bind_int(stmt.handle, i, val); return nothing)
bind!(stmt::_Stmt, i::Integer, val::Int64)          = (stmt.params[i] = val; @CHECK stmt.db sqlite3_bind_int64(stmt.handle, i, val); return nothing)
bind!(stmt::_Stmt, i::Integer, val::Missing)        = (stmt.params[i] = val; @CHECK stmt.db sqlite3_bind_null(stmt.handle, i); return nothing)
bind!(stmt::_Stmt, i::Integer, val::Nothing)        = (stmt.params[i] = val; @CHECK stmt.db sqlite3_bind_null(stmt.handle, i); return nothing)
bind!(stmt::_Stmt, i::Integer, val::AbstractString) = (stmt.params[i] = val; @CHECK stmt.db sqlite3_bind_text(stmt.handle, i, val); return nothing)
bind!(stmt::_Stmt, i::Integer, val::WeakRefString{UInt8})   = (stmt.params[i] = val; @CHECK stmt.db sqlite3_bind_text(stmt.handle, i, val.ptr, val.len); return nothing)
bind!(stmt::_Stmt, i::Integer, val::WeakRefString{UInt16})  = (stmt.params[i] = val; @CHECK stmt.db sqlite3_bind_text16(stmt.handle, i, val.ptr, val.len*2); return nothing)
bind!(stmt::_Stmt, i::Integer, val::Bool)           = (stmt.params[i] = val; @CHECK stmt.db sqlite3_bind_int(stmt.handle, i, Int32(val)); return nothing)
bind!(stmt::_Stmt, i::Integer, val::Vector{UInt8})  = (stmt.params[i] = val; @CHECK stmt.db sqlite3_bind_blob(stmt.handle, i, val); return nothing)
# Fallback is BLOB and defaults to serializing the julia value

bind!(stmt::Stmt, param::Union{Integer, AbstractString}, val::Any) = bind!(_stmt(stmt), param, val)

# internal wrapper mutable struct to, in-effect, mark something which has been serialized
struct Serialized
    object
end

const GLOBAL_BUF = IOBuffer()
function sqlserialize(x)
    seekstart(GLOBAL_BUF)
    # deserialize will sometimes return a random object when called on an array
    # which has not been previously serialized, we can use this mutable struct to check
    # that the array has been serialized
    s = Serialized(x)
    Serialization.serialize(GLOBAL_BUF, s)
    return take!(GLOBAL_BUF)
end
# fallback method to bind arbitrary julia `val` to the parameter at index `i` (object is serialized)
bind!(stmt::_Stmt, i::Integer, val::Any) = bind!(stmt, i, sqlserialize(val))

struct SerializeError <: Exception
    msg::String
end

# magic bytes that indicate that a value is in fact a serialized julia value, instead of just a byte vector
# these bytes depend on the julia version and other things, so they are determined using an actual serialization
const SERIALIZATION = sqlserialize(0)[1:18]

function sqldeserialize(r)
    ret = ccall(:memcmp, Int32, (Ptr{UInt8}, Ptr{UInt8}, UInt),
            SERIALIZATION, r, min(sizeof(SERIALIZATION), sizeof(r)))
    if ret == 0
        try
            v = Serialization.deserialize(IOBuffer(r))
            return v.object
        catch e
            throw(SerializeError("Error deserializing non-primitive value out of database; this is probably due to using SQLite.jl with a different Julia version than was used to originally serialize the database values. The same Julia version that was used to serialize should be used to extract the database values into a different format (csv file, feather file, etc.) and then loaded back into the sqlite database with the current Julia version."))
        end
    else
        return r
    end
end
#TODO:
 #int sqlite3_bind_zeroblob(sqlite3_stmt*, int, int n);
 #int sqlite3_bind_value(sqlite3_stmt*, int, const sqlite3_value*);

# get julia type for given column of the given statement
function juliatype(handle, col)
    stored_typeid = SQLite.sqlite3_column_type(handle, col)
    if stored_typeid == SQLite.SQLITE_BLOB
        # blobs are serialized julia types, so just try to deserialize it
        deser_val = SQLite.sqlitevalue(Any, handle, col)
        # FIXME deserialized type have priority over declared type, is it fine?
        return typeof(deser_val)
    else
        stored_type = juliatype(stored_typeid)
    end
    decl_typestr = SQLite.sqlite3_column_decltype(handle, col)
    if decl_typestr != C_NULL
        return juliatype(unsafe_string(decl_typestr), stored_type)
    else
        return stored_type
    end
end

# convert SQLite stored type into Julia equivalent
juliatype(x::Integer) =
    x == SQLITE_INTEGER ? Int64 :
    x == SQLITE_FLOAT ? Float64 :
    x == SQLITE_TEXT ? String :
    x == SQLITE_NULL ? Missing :
    Any

# convert SQLite declared type into Julia equivalent,
# fall back to default (stored type), if no good match
function juliatype(decl_typestr::AbstractString,
                   default::Type = Any)
    typeuc = uppercase(decl_typestr)
    if typeuc in ("INTEGER", "INT")
        return Int64
    elseif typeuc in ("NUMERIC", "REAL", "FLOAT")
        return Float64
    elseif typeuc == "TEXT"
        return String
    elseif typeuc == "BLOB"
        return Any
    elseif typeuc == "DATETIME"
        return default # FIXME
    elseif typeuc == "TIMESTAMP"
        return default # FIXME
    elseif occursin(r"^(?:N?VAR)?CHAR\(\d+\)$", typeuc)
        return String
    elseif occursin(r"^NUMERIC\(\d+,\d+\)$", typeuc)
        return Float64
    else
        @warn "Unsupported SQLite declared type $decl_typestr, falling back to $default type"
        return default
    end
end

sqlitevalue(::Type{T}, handle, col) where {T <: Union{Base.BitSigned, Base.BitUnsigned}} = convert(T, sqlite3_column_int64(handle, col))
const FLOAT_TYPES = Union{Float16, Float32, Float64} # exclude BigFloat
sqlitevalue(::Type{T}, handle, col) where {T <: FLOAT_TYPES} = convert(T, sqlite3_column_double(handle, col))
#TODO: test returning a WeakRefString instead of calling `unsafe_string`
sqlitevalue(::Type{T}, handle, col) where {T <: AbstractString} = convert(T, unsafe_string(sqlite3_column_text(handle, col)))
function sqlitevalue(::Type{T}, handle, col) where {T}
    blob = convert(Ptr{UInt8}, sqlite3_column_blob(handle, col))
    b = sqlite3_column_bytes(handle, col)
    buf = zeros(UInt8, b) # global const?
    unsafe_copyto!(pointer(buf), blob, b)
    r = sqldeserialize(buf)::T
    return r
end

# conversion from Julia to SQLite3 types
sqlitetype_(::Type{<:Integer}) = "INT"
sqlitetype_(::Type{<:AbstractFloat}) = "REAL"
sqlitetype_(::Type{<:AbstractString}) = "TEXT"
sqlitetype_(::Type{Bool}) = "INT"
sqlitetype_(::Type) = "BLOB" # fallback

sqlitetype(::Type{Missing}) = "NULL"
sqlitetype(::Type{Nothing}) = "NULL"
sqlitetype(::Type{Union{T, Missing}}) where T = sqlitetype_(T)
sqlitetype(::Type{T}) where T = string(sqlitetype_(T), " NOT NULL")

"""
    SQLite.execute(db::SQLite.DB, sql::AbstractString, [params]) -> Int
    SQLite.execute(stmt::SQLite.Stmt, [params]) -> Int

An internal method that executes the SQL statement (provided either as a `db` connection and `sql` command,
or as an already prepared `stmt` (see [`SQLite.Stmt`](@ref))) with given `params` parameters
(either positional (`Vector` or `Tuple`), named (`Dict` or `NamedTuple`), or specified as keyword arguments).

Returns the SQLite status code of operation.

*Note*: this is a low-level method that just executes the SQL statement,
but does not retrieve any data from `db`.
To get the results of a SQL query, it is recommended to use [`DBInterface.execute`](@ref).
"""
function execute end

function execute(db::DB, stmt::_Stmt, params::DBInterface.StatementParams=())
    sqlite3_reset(stmt.handle)
    bind!(stmt, params)
    r = sqlite3_step(stmt.handle)
    if r == SQLITE_DONE
        sqlite3_reset(stmt.handle)
    elseif r != SQLITE_ROW
        e = sqliteexception(db)
        sqlite3_reset(stmt.handle)
        throw(e)
    end
    return r
end

execute(stmt::Stmt, params::DBInterface.StatementParams) =
    execute(stmt.db, _stmt(stmt), params)

execute(stmt::Stmt; kwargs...) = execute(stmt, kwargs.data)

function execute(db::DB, sql::AbstractString, params::DBInterface.StatementParams)
     # prepare without registering _Stmt in DB
    _stmt = _Stmt(db, sql)
    try
        return execute(db, _stmt, params)
    finally
        _close!(_stmt) # immediately close, don't wait for GC
    end
end

execute(db::DB, sql::AbstractString; kwargs...) = execute(db, sql, kwargs.data)

"""
    SQLite.esc_id(x::Union{AbstractString,Vector{AbstractString}})

Escape SQLite identifiers
(e.g. column, table or index names).
Can be either a string or a vector of strings
(note does not check for null characters).
A vector of identifiers will be separated by commas.

Example:

```julia
julia> using SQLite, DataFrames

julia> df = DataFrame(label=string.(rand("abcdefg", 10)), value=rand(10));

julia> db = SQLite.DB(mktemp()[1]);

julia> tbl |> SQLite.load!(db, "temp");

julia> DBInterface.execute(db,"SELECT * FROM temp WHERE label IN ('a','b','c')") |> DataFrame
4×2 DataFrame
│ Row │ label   │ value    │
│     │ String⍰ │ Float64⍰ │
├─────┼─────────┼──────────┤
│ 1   │ c       │ 0.603739 │
│ 2   │ c       │ 0.429831 │
│ 3   │ b       │ 0.799696 │
│ 4   │ a       │ 0.603586 │

julia> q = ['a','b','c'];

julia> DBInterface.execute(db,"SELECT * FROM temp WHERE label IN (\$(SQLite.esc_id(q)))") |> DataFrame
4×2 DataFrame
│ Row │ label   │ value    │
│     │ String⍰ │ Float64⍰ │
├─────┼─────────┼──────────┤
│ 1   │ c       │ 0.603739 │
│ 2   │ c       │ 0.429831 │
│ 3   │ b       │ 0.799696 │
│ 4   │ a       │ 0.603586 │
```
"""
function esc_id end

esc_id(x::AbstractString) = "\"" * replace(x, "\""=>"\"\"") * "\""
esc_id(X::AbstractVector{S}) where {S <: AbstractString} = join(map(esc_id, X), ',')

# Transaction-based commands
"""
    SQLite.transaction(db, mode="DEFERRED")
    SQLite.transaction(func, db)

Begin a transaction in the specified `mode`, default = "DEFERRED".

If `mode` is one of "", "DEFERRED", "IMMEDIATE" or "EXCLUSIVE" then a
transaction of that (or the default) mutable struct is started. Otherwise a savepoint
is created whose name is `mode` converted to AbstractString.

In the second method, `func` is executed within a transaction (the transaction being committed upon successful execution)
"""
function transaction end

function transaction(db::DB, mode="DEFERRED")
    execute(db, "PRAGMA temp_store=MEMORY;")
    if uppercase(mode) in ["", "DEFERRED", "IMMEDIATE", "EXCLUSIVE"]
        execute(db, "BEGIN $(mode) TRANSACTION;")
    else
        execute(db, "SAVEPOINT $(mode);")
    end
end

@inline function transaction(f::Function, db::DB)
    # generate a random name for the savepoint
    name = string("SQLITE", Random.randstring(10))
    execute(db, "PRAGMA synchronous = OFF;")
    transaction(db, name)
    try
        f()
    catch
        rollback(db, name)
        rethrow()
    finally
        # savepoints are not released on rollback
        commit(db, name)
        execute(db, "PRAGMA synchronous = ON;")
    end
end

"""
    SQLite.commit(db)
    SQLite.commit(db, name)

commit a transaction or named savepoint
"""
function commit end

commit(db::DB) = execute(db, "COMMIT TRANSACTION;")
commit(db::DB, name::AbstractString) = execute(db, "RELEASE SAVEPOINT $(name);")

"""
    SQLite.rollback(db)
    SQLite.rollback(db, name)

rollback transaction or named savepoint
"""
function rollback end

rollback(db::DB) = execute(db, "ROLLBACK TRANSACTION;")
rollback(db::DB, name::AbstractString) = execute(db, "ROLLBACK TRANSACTION TO SAVEPOINT $(name);")

"""
    SQLite.drop!(db, table; ifexists::Bool=true)

drop the SQLite table `table` from the database `db`; `ifexists=true` will prevent an error being thrown if `table` doesn't exist
"""
function drop!(db::DB, table::AbstractString; ifexists::Bool=false)
    exists = ifexists ? "IF EXISTS" : ""
    transaction(db) do
        execute(db, "DROP TABLE $exists $(esc_id(table))")
    end
    execute(db, "VACUUM")
    return
end

"""
    SQLite.dropindex!(db, index; ifexists::Bool=true)

drop the SQLite index `index` from the database `db`; `ifexists=true` will not return an error if `index` doesn't exist
"""
function dropindex!(db::DB, index::AbstractString; ifexists::Bool=false)
    exists = ifexists ? "IF EXISTS" : ""
    transaction(db) do
        execute(db, "DROP INDEX $exists $(esc_id(index))")
    end
    return
end

"""
    SQLite.createindex!(db, table, index, cols; unique=true, ifnotexists=false)

create the SQLite index `index` on the table `table` using `cols`,
which may be a single column or vector of columns.
`unique` specifies whether the index will be unique or not.
`ifnotexists=true` will not throw an error if the index already exists
"""
function createindex!(db::DB, table::AbstractString, index::AbstractString, cols::Union{S, AbstractVector{S}};
                      unique::Bool=true, ifnotexists::Bool=false) where {S <: AbstractString}
    u = unique ? "UNIQUE" : ""
    exists = ifnotexists ? "IF NOT EXISTS" : ""
    transaction(db) do
        execute(db, "CREATE $u INDEX $exists $(esc_id(index)) ON $(esc_id(table)) ($(esc_id(cols)))")
    end
    execute(db, "ANALYZE $index")
    return
end

"""
    SQLite.removeduplicates!(db, table, cols)

Removes duplicate rows from `table` based on the values in `cols`, which is an array of column names.

A convenience method for the common task of removing duplicate
rows in a dataset according to some subset of columns that make up a "primary key".
"""
function removeduplicates!(db::DB, table::AbstractString, cols::AbstractArray{T}) where {T <: AbstractString}
    colsstr = ""
    for c in cols
       colsstr = colsstr * esc_id(c) * ","
    end
    colsstr = chop(colsstr)
    transaction(db) do
        execute(db, "DELETE FROM $(esc_id(table)) WHERE _ROWID_ NOT IN (SELECT max(_ROWID_) from $(esc_id(table)) GROUP BY $(colsstr));")
    end
    execute(db, "ANALYZE $table")
    return
 end

include("tables.jl")

"""
    SQLite.tables(db, sink=columntable)

returns a list of tables in `db`
"""
tables(db::DB, sink=columntable) = DBInterface.execute(sink, db, "SELECT name FROM sqlite_master WHERE type='table';")

"""
    SQLite.indices(db, sink=columntable)

returns a list of indices in `db`
"""
indices(db::DB, sink=columntable) = DBInterface.execute(sink, db, "SELECT name FROM sqlite_master WHERE type='index';")

"""
    SQLite.columns(db, table, sink=columntable)

returns a list of columns in `table`
"""
columns(db::DB, table::AbstractString, sink=columntable) = DBInterface.execute(sink, db, "PRAGMA table_info($(esc_id(table)))")

"""
    SQLite.last_insert_rowid(db)

returns the auto increment id of the last row
"""
last_insert_rowid(db::DB) = sqlite3_last_insert_rowid(db.handle)

"""
    SQLite.enable_load_extension(db, enable::Bool=true)

Enables extension loading (off by default) on the sqlite database `db`. Pass `false` as the second argument to disable.
"""
function enable_load_extension(db::DB, enable::Bool=true)
   ccall((:sqlite3_enable_load_extension, SQLite.libsqlite), Cint, (Ptr{Cvoid}, Cint), db.handle, enable)
end

"""
    SQLite.busy_timeout(db, ms::Integer=0)

Set a busy handler that sleeps for a specified amount of milliseconds  when a table is locked. After at least ms milliseconds of sleeping, the handler will return 0, causing sqlite to return SQLITE_BUSY.
"""
function busy_timeout(db::DB, ms::Integer=0)
    sqlite3_busy_timeout(db.handle, ms)
end



end # module
