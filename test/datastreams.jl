
# DataFrames
FILE = joinpath(DSTESTDIR, "randoms_small.csv")
DF = readtable(FILE)
for i = 1:5
    T = eltype(DF.columns[i])
    DF.columns[i] = DataArray(T[isna(x) ? (T <: String ? "" : zero(T)) : x for x in DF.columns[i]], [isna(x) for x in DF.columns[i]])
end
DF.columns[6] = DataArray(Date[isna(x) ? Date() : Date(x) for x in DF[:hiredate]], [isna(x) for x in DF[:hiredate]])
DF.columns[7] = DataArray(DateTime[isna(x) ? DateTime() : DateTime(x) for x in DF[:lastclockin]], [isna(x) for x in DF[:lastclockin]])
DF2 = deepcopy(DF)
dfsource = Tester("DataFrame", x->x, false, DataFrame, (:DF,), scalartransforms, vectortransforms, x->x, x->nothing)
dfsink = Tester("DataFrame", x->x, false, DataFrame, (:DF2,), scalartransforms, vectortransforms, x->x, x->nothing)
function DataFrames.DataFrame(sym::Symbol; append::Bool=false)
    return @eval $sym
end
function DataFrames.DataFrame(sch::Data.Schema, ::Type{Data.Field}, append::Bool, ref::Vector{UInt8}, sym::Symbol)
    return DataFrame(DataFrame(sym), sch, Data.Field, append, ref)
end
function DataFrame(sink, sch::Data.Schema, ::Type{Data.Field}, append::Bool, ref::Vector{UInt8})
    rows, cols = size(sch)
    newsize = max(0, rows) + (append ? size(sink, 1) : 0)
    # need to make sure we don't break a NullableVector{WeakRefString{UInt8}} when appending
    if append
        for (i, T) in enumerate(Data.types(sch))
            if T <: Nullable{WeakRefString{UInt8}}
                sink.columns[i] = DataArray(String[string(x) for x in sink.columns[i]])
                sch.types[i] = Nullable{String}
            end
        end
    else
        for (i, T) in enumerate(Data.types(sch))
            if T != eltype(sink.columns[i])
                sink.columns[i] = DataArray(eltype(T), newsize)
            end
        end
    end
    newsize != size(sink, 1) && foreach(x->resize!(x, newsize), sink.columns)
    if !append
        for (i, T) in enumerate(eltypes(sink))
            if T <: Nullable{WeakRefString{UInt8}}
                sink.columns[i] = DataVector{String}(Vector{String}(newsize), fill(true, newsize), isempty(ref) ? UInt8[] : ref)
            end
        end
    end
    sch.rows = newsize
    return sink
end

# SQLite
dbfile = joinpath(dirname(@__FILE__), "randoms.sqlite")
dbfile2 = joinpath(dirname(@__FILE__),"test2.sqlite")
db = SQLite.DB(dbfile)
SQLite.load(db, "randoms_small", DF)
cp(dbfile, dbfile2; remove_destination=true)
db2 = SQLite.DB(dbfile2)
SQLite.createtable!(db2, "randoms2_small", Data.schema(SQLite.Source(db2, "select * from randoms_small")))
sqlitesource = Tester("SQLite.Source", SQLite.query, true, SQLite.Source, (db2, "select * from randoms_small"), scalartransforms, vectortransforms, x->x, ()->nothing)
sqlitesink = Tester("SQLite.Sink", SQLite.load, true, SQLite.Sink, (db2, "randoms2_small"), scalartransforms, vectortransforms, x->SQLite.query(db2, "select * from randoms2_small"), (x,y)->nothing)

DataStreamsIntegrationTests.teststream([dfsource, sqlitesource], [dfsink, sqlitesink]; rows=99)
finalize(db)
finalize(db2)
db = db2 = nothing;
gc(); gc();
rm(dbfile)
rm(dbfile2)