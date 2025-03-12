const std = @import("std");
pub const c = @cImport({
    @cInclude("sqlite3.h");
});
const log = std.log.scoped(.SQLITE);

pub const Result = enum(c_int) {
    OK = c.SQLITE_OK,
    ROW = c.SQLITE_ROW,
    DONE = c.SQLITE_DONE,
};

pub fn global_error_msg() [:0]const u8 {
    return std.mem.span(c.sqlite3_errmsg(null));
}

pub const ColumnType = enum(c_int) {
    INTEGER = c.SQLITE_INTEGER,
    FLOAT = c.SQLITE_FLOAT,
    TEXT = c.SQLITE_TEXT,
    BLOB = c.SQLITE_BLOB,
    NULL = c.SQLITE_NULL,
};

pub const Connection = struct {
    db: ?*c.sqlite3,
    pub fn open(filename: [:0]const u8) Error!Connection {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(filename, &db);
        if (rc != c.SQLITE_OK) {
            const err = error_from_int(rc);
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(null) });
            return err;
        }
        _ = c.sqlite3_extended_result_codes(db, 1);
        return .{ .db = db };
    }
    pub fn close(self: Connection) void {
        const rc = c.sqlite3_close(self.db);
        if (rc != c.SQLITE_OK) {
            const err = error_from_int(rc);
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(null) });
        }
    }

    pub fn error_msg(self: Connection) [:0]const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.db));
    }

    pub fn prepare_v2(self: Connection, sql: [:0]const u8) Error!Statement {
        log.debug("Preparing query! sql='{s}'", .{sql});
        var stmt: Statement = undefined;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt.stmt, null);
        if (rc != c.SQLITE_OK) {
            const err = error_from_int(rc);
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(self.db) });
            return err;
        }
        stmt.conn = self;
        return stmt;
    }

    pub fn exec(self: Connection, sql: [:0]const u8) Error!void {
        log.debug("Running query sql='{s}'", .{sql});
        const rc = c.sqlite3_exec(self.db, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) {
            const err = error_from_int(rc);
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(self.db) });
            return err;
        }
    }
};

pub const Statement = struct {
    conn: Connection,
    stmt: ?*c.sqlite3_stmt,
    pub fn bind_null(self: Statement, index: comptime_int) Error!void {
        const rc = c.sqlite3_bind_null(self.stmt, index + 1);
        if (rc != c.SQLITE_OK) {
            const err = error_from_int(rc);
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(self.conn.db) });
            return err;
        }
    }
    pub fn bind_text(self: Statement, index: comptime_int, value: [:0]const u8) Error!void {
        const rc = c.sqlite3_bind_text(self.stmt, index + 1, value.ptr, @intCast(value.len), null);
        if (rc != c.SQLITE_OK) {
            const err = error_from_int(rc);
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(self.conn.db) });
            return err;
        }
    }
    pub fn bind_i32(self: Statement, index: comptime_int, value: i32) Error!void {
        const rc = c.sqlite3_bind_int(self.stmt, index + 1, value);
        if (rc != c.SQLITE_OK) {
            const err = error_from_int(rc);
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(self.conn.db) });
            return err;
        }
    }
    pub fn bind_i64(self: Statement, index: comptime_int, value: i64) Error!void {
        const rc = c.sqlite3_bind_int64(self.stmt, index + 1, value);
        if (rc != c.SQLITE_OK) {
            const err = error_from_int(rc);
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(self.conn.db) });
            return err;
        }
    }
    pub fn bind_float(self: Statement, index: comptime_int, value: i64) Error!void {
        const rc = c.sqlite3_bind_double(self.stmt, index + 1, value);
        if (rc != c.SQLITE_OK) {
            const err = error_from_int(rc);
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(self.conn.db) });
            return err;
        }
    }
    pub fn bind_blob(self: Statement, index: comptime_int, value: []const u8) Error!void {
        const rc = c.sqlite3_bind_blob(self.stmt, index + 1, value.ptr, @intCast(value.len), null);
        if (rc != c.SQLITE_OK) {
            const err = error_from_int(rc);
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(self.conn.db) });
            return err;
        }
    }
    pub fn column_type(self: Statement, index: comptime_int) ColumnType {
        const t = c.sqlite3_column_type(self.stmt, index);
        return std.meta.intToEnum(ColumnType, t) catch unreachable;
    }
    pub fn column_len(self: Statement, index: comptime_int) usize {
        return @intCast(c.sqlite3_column_bytes(self.stmt, index));
    }
    pub fn column_i32(self: Statement, index: comptime_int) i32 {
        return c.sqlite3_column_int(self.stmt, index);
    }
    pub fn column_i64(self: Statement, index: comptime_int) i64 {
        return c.sqlite3_column_int64(self.stmt, index);
    }
    pub fn column_text(self: Statement, index: comptime_int) Error![:0]const u8 {
        const c_text = c.sqlite3_column_text(self.stmt, index);
        if (c_text == null) {
            const err = error_from_int(c.sqlite3_extended_errcode(self.conn.db));
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(self.conn.db) });
            return err;
        }
        return std.mem.span(c_text);
    }
    pub fn column_blob(self: Statement, index: comptime_int) Error![]const u8 {
        const len = c.sqlite3_column_bytes(self.stmt, index);
        const c_blob = c.sqlite3_column_blob(self.stmt, index);
        if (c_blob == null) {
            const err = error_from_int(c.sqlite3_extended_errcode(self.conn.db));
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(self.conn.db) });
            return err;
        }
        var c_slice: []const u8 = undefined;
        c_slice.len = len;
        c_slice.ptr = c_blob;
        return c_slice;
    }
    pub fn step(self: Statement) Error!Result {
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_ROW or rc == c.SQLITE_DONE or rc == c.SQLITE_OK) {
            return @enumFromInt(rc);
        } else {
            const err = error_from_int(rc);
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(self.conn.db) });
            return err;
        }
    }
    pub fn finalize(self: Statement) Error!void {
        const rc = c.sqlite3_finalize(self.stmt);
        if (rc != c.SQLITE_OK) {
            const err = error_from_int(rc);
            log.err("{s}: {s}", .{ @errorName(err), c.sqlite3_errmsg(self.conn.db) });
            return err;
        }
    }
};

pub const GenericError = error{
    ERROR_MISSING_COLLSEQ,
    ERROR_RETRY,
    ERROR_SNAPSHOT,
};

pub const IOError = error{
    IO_READ,
    IO_SHORT_READ,
    IO_WRITE,
    IO_FSYNC,
    IO_DIR_FSYNC,
    IO_TRUNCATE,
    IO_FSTAT,
    IO_UNLOCK,
    IO_RDLOCK,
    IO_DELETE,
    IO_BLOCKED,
    IO_NOMEM,
    IO_ACCESS,
    IO_CHECK_RESERVED_LOCK,
    IO_LOCK,
    IO_CLOSE,
    IO_DIR_CLOSE,
    IO_SHM_OPEN,
    IO_SHM_SIZE,
    IO_SHM_LOCK,
    IO_SHM_MAP,
    IO_SEEK,
    IO_DELETE_NOENT,
    IO_MMAP,
    IO_GET_TEMP_PATH,
    IO_CONV_PATH,
    IO_VNODE,
    IO_AUTH,
    IO_BEGIN_ATOMIC,
    IO_COMMIT_ATOMIC,
    IO_ROLLBACK_ATOMIC,
    IO_DATA,
    IO_CORRUPT_FS,
    IO_IN_PAGE,
};

pub const LockedError = error{
    LOCKED_SHARED_CACHE,
    LOCKED_VTAB,
};

pub const BusyError = error{
    BUSY_RECOVERY,
    BUSY_SNAPSHOT,
    BUSY_TIMEOUT,
};

pub const CantOpenError = error{
    CANTOPEN_NO_TEMP_DIR,
    CANTOPEN_IS_DIR,
    CANTOPEN_FULL_PATH,
    CANTOPEN_CONV_PATH,
    CANTOPEN_DIRTY_WAL,
    CANTOPEN_SYMLINK,
};

pub const CorruptError = error{
    CORRUPT_VTAB,
    CORRUPT_SEQUENCE,
    CORRUPT_INDEX,
};

pub const ReadOnlyError = error{
    READONLY_RECOVERY,
    READONLY_CANT_LOCK,
    READONLY_ROLLBACK,
    READONLY_DB_MOVED,
    READONLY_CANT_INIT,
    READONLY_DIRECTORY,
};

pub const AbortError = error{
    ABORT_ROLLBACK,
};

pub const ConstraintError = error{
    CONSTRAINT_CHECK,
    CONSTRAINT_COMMIT_HOOK,
    CONSTRAINT_FOREIGN_KEY,
    CONSTRAINT_FUNCTION,
    CONSTRAINT_NOT_NULL,
    CONSTRAINT_PRIMARY_KEY,
    CONSTRAINT_TRIGGER,
    CONSTRAINT_UNIQUE,
    CONSTRAINT_VTAB,
    CONSTRAINT_ROW_ID,
    CONSTRAINT_PINNED,
    CONSTRAINT_DATATYPE,
};

pub const NoticeError = error{
    NOTICE_RECOVER_WAL,
    NOTICE_RECOVER_ROLLBACK,
    NOTICE_RBU,
};

pub const AuthError = error{
    AUTH_USER,
};

pub const BaseError = error{
    // SQLITE
    ERROR,
    INTERNAL,
    PERM,
    ABORT,
    BUSY,
    LOCKED,
    NOMEM,
    READONLY,
    INTERRUPT,
    IOERR,
    CORRUPT,
    NOTFOUND,
    FULL,
    CANTOPEN,
    PROTOCOL,
    EMPTY,
    SCHEMA,
    TOOBIG,
    CONSTRAINT,
    MISMATCH,
    MISUSE,
    NOLFS,
    AUTH,
    FORMAT,
    RANGE,
    NOTADB,
    NOTICE,
};

pub const Error = BaseError || IOError || LockedError || BusyError || CantOpenError || CorruptError ||
    ReadOnlyError || AbortError || ConstraintError || NoticeError || AuthError;

fn error_from_int(val: c_int) Error {
    const base: u8 = @intCast(val & 0xFF);
    switch (base) {
        c.SQLITE_ERROR => return BaseError.ERROR,
        c.SQLITE_INTERNAL => return BaseError.INTERNAL,
        c.SQLITE_PERM => return BaseError.PERM,
        c.SQLITE_ABORT => switch (val) {
            c.SQLITE_ABORT_ROLLBACK => return AbortError.ABORT_ROLLBACK,
            else => return BaseError.ABORT,
        },
        c.SQLITE_BUSY => switch (val) {
            c.SQLITE_BUSY_RECOVERY => return BusyError.BUSY_RECOVERY,
            c.SQLITE_BUSY_SNAPSHOT => return BusyError.BUSY_SNAPSHOT,
            c.SQLITE_BUSY_TIMEOUT => return BusyError.BUSY_TIMEOUT,
            else => return BaseError.BUSY,
        },
        c.SQLITE_LOCKED => switch (val) {
            c.SQLITE_LOCKED_SHAREDCACHE => return LockedError.LOCKED_SHARED_CACHE,
            c.SQLITE_LOCKED_VTAB => return LockedError.LOCKED_VTAB,
            else => return BaseError.LOCKED,
        },
        c.SQLITE_NOMEM => return BaseError.NOMEM,
        c.SQLITE_READONLY => switch (val) {
            c.SQLITE_READONLY_RECOVERY => return ReadOnlyError.READONLY_RECOVERY,
            c.SQLITE_READONLY_CANTLOCK => return ReadOnlyError.READONLY_CANT_LOCK,
            c.SQLITE_READONLY_ROLLBACK => return ReadOnlyError.READONLY_ROLLBACK,
            c.SQLITE_READONLY_DBMOVED => return ReadOnlyError.READONLY_DB_MOVED,
            c.SQLITE_READONLY_CANTINIT => return ReadOnlyError.READONLY_CANT_INIT,
            c.SQLITE_READONLY_DIRECTORY => return ReadOnlyError.READONLY_DIRECTORY,
            else => return BaseError.READONLY,
        },
        c.SQLITE_INTERRUPT => return BaseError.INTERRUPT,
        c.SQLITE_IOERR => switch (val) {
            c.SQLITE_IOERR_READ => return IOError.IO_READ,
            c.SQLITE_IOERR_SHORT_READ => return IOError.IO_SHORT_READ,
            c.SQLITE_IOERR_WRITE => return IOError.IO_WRITE,
            c.SQLITE_IOERR_FSYNC => return IOError.IO_FSYNC,
            c.SQLITE_IOERR_DIR_FSYNC => return IOError.IO_DIR_FSYNC,
            c.SQLITE_IOERR_TRUNCATE => return IOError.IO_TRUNCATE,
            c.SQLITE_IOERR_FSTAT => return IOError.IO_FSTAT,
            c.SQLITE_IOERR_UNLOCK => return IOError.IO_UNLOCK,
            c.SQLITE_IOERR_RDLOCK => return IOError.IO_RDLOCK,
            c.SQLITE_IOERR_DELETE => return IOError.IO_DELETE,
            c.SQLITE_IOERR_BLOCKED => return IOError.IO_BLOCKED,
            c.SQLITE_IOERR_NOMEM => return IOError.IO_NOMEM,
            c.SQLITE_IOERR_ACCESS => return IOError.IO_ACCESS,
            c.SQLITE_IOERR_CHECKRESERVEDLOCK => return IOError.IO_CHECK_RESERVED_LOCK,
            c.SQLITE_IOERR_LOCK => return IOError.IO_LOCK,
            c.SQLITE_IOERR_CLOSE => return IOError.IO_CLOSE,
            c.SQLITE_IOERR_DIR_CLOSE => return IOError.IO_DIR_CLOSE,
            c.SQLITE_IOERR_SHMOPEN => return IOError.IO_SHM_OPEN,
            c.SQLITE_IOERR_SHMSIZE => return IOError.IO_SHM_SIZE,
            c.SQLITE_IOERR_SHMLOCK => return IOError.IO_SHM_LOCK,
            c.SQLITE_IOERR_SHMMAP => return IOError.IO_SHM_MAP,
            c.SQLITE_IOERR_SEEK => return IOError.IO_SEEK,
            c.SQLITE_IOERR_DELETE_NOENT => return IOError.IO_DELETE_NOENT,
            c.SQLITE_IOERR_MMAP => return IOError.IO_MMAP,
            c.SQLITE_IOERR_GETTEMPPATH => return IOError.IO_GET_TEMP_PATH,
            c.SQLITE_IOERR_CONVPATH => return IOError.IO_CONV_PATH,
            c.SQLITE_IOERR_VNODE => return IOError.IO_VNODE,
            c.SQLITE_IOERR_AUTH => return IOError.IO_AUTH,
            c.SQLITE_IOERR_BEGIN_ATOMIC => return IOError.IO_BEGIN_ATOMIC,
            c.SQLITE_IOERR_COMMIT_ATOMIC => return IOError.IO_COMMIT_ATOMIC,
            c.SQLITE_IOERR_ROLLBACK_ATOMIC => return IOError.IO_ROLLBACK_ATOMIC,
            c.SQLITE_IOERR_DATA => return IOError.IO_DATA,
            c.SQLITE_IOERR_CORRUPTFS => return IOError.IO_CORRUPT_FS,
            c.SQLITE_IOERR_IN_PAGE => return IOError.IO_IN_PAGE,
            else => return BaseError.IOERR,
        },
        c.SQLITE_CORRUPT => switch (val) {
            c.SQLITE_CORRUPT_VTAB => return CorruptError.CORRUPT_VTAB,
            c.SQLITE_CORRUPT_SEQUENCE => return CorruptError.CORRUPT_SEQUENCE,
            c.SQLITE_CORRUPT_INDEX => return CorruptError.CORRUPT_INDEX,
            else => return BaseError.CORRUPT,
        },
        c.SQLITE_NOTFOUND => return BaseError.NOTFOUND,
        c.SQLITE_FULL => return BaseError.FULL,
        c.SQLITE_CANTOPEN => switch (val) {
            c.SQLITE_CANTOPEN_NOTEMPDIR => return CantOpenError.CANTOPEN_NO_TEMP_DIR,
            c.SQLITE_CANTOPEN_ISDIR => return CantOpenError.CANTOPEN_IS_DIR,
            c.SQLITE_CANTOPEN_FULLPATH => return CantOpenError.CANTOPEN_FULL_PATH,
            c.SQLITE_CANTOPEN_CONVPATH => return CantOpenError.CANTOPEN_CONV_PATH,
            c.SQLITE_CANTOPEN_DIRTYWAL => return CantOpenError.CANTOPEN_DIRTY_WAL,
            c.SQLITE_CANTOPEN_SYMLINK => return CantOpenError.CANTOPEN_SYMLINK,
            else => return BaseError.CANTOPEN,
        },
        c.SQLITE_PROTOCOL => return BaseError.PROTOCOL,
        c.SQLITE_EMPTY => return BaseError.EMPTY,
        c.SQLITE_SCHEMA => return BaseError.SCHEMA,
        c.SQLITE_TOOBIG => return BaseError.TOOBIG,
        c.SQLITE_CONSTRAINT => switch (val) {
            c.SQLITE_CONSTRAINT_CHECK => return ConstraintError.CONSTRAINT_CHECK,
            c.SQLITE_CONSTRAINT_COMMITHOOK => return ConstraintError.CONSTRAINT_COMMIT_HOOK,
            c.SQLITE_CONSTRAINT_FOREIGNKEY => return ConstraintError.CONSTRAINT_FOREIGN_KEY,
            c.SQLITE_CONSTRAINT_FUNCTION => return ConstraintError.CONSTRAINT_FUNCTION,
            c.SQLITE_CONSTRAINT_NOTNULL => return ConstraintError.CONSTRAINT_NOT_NULL,
            c.SQLITE_CONSTRAINT_PRIMARYKEY => return ConstraintError.CONSTRAINT_PRIMARY_KEY,
            c.SQLITE_CONSTRAINT_TRIGGER => return ConstraintError.CONSTRAINT_TRIGGER,
            c.SQLITE_CONSTRAINT_UNIQUE => return ConstraintError.CONSTRAINT_UNIQUE,
            c.SQLITE_CONSTRAINT_VTAB => return ConstraintError.CONSTRAINT_VTAB,
            c.SQLITE_CONSTRAINT_ROWID => return ConstraintError.CONSTRAINT_ROW_ID,
            c.SQLITE_CONSTRAINT_PINNED => return ConstraintError.CONSTRAINT_PINNED,
            c.SQLITE_CONSTRAINT_DATATYPE => return ConstraintError.CONSTRAINT_DATATYPE,
            else => return BaseError.CONSTRAINT,
        },
        c.SQLITE_MISMATCH => return BaseError.MISMATCH,
        c.SQLITE_MISUSE => return BaseError.MISUSE,
        c.SQLITE_NOLFS => return BaseError.NOLFS,
        c.SQLITE_AUTH => switch (val) {
            c.SQLITE_AUTH_USER => return AuthError.AUTH_USER,
            else => return BaseError.AUTH,
        },
        c.SQLITE_FORMAT => return BaseError.FORMAT,
        c.SQLITE_RANGE => return BaseError.RANGE,
        c.SQLITE_NOTADB => return BaseError.NOTADB,
        c.SQLITE_NOTICE => switch (val) {
            c.SQLITE_NOTICE_RECOVER_WAL => return NoticeError.NOTICE_RECOVER_WAL,
            c.SQLITE_NOTICE_RECOVER_ROLLBACK => return NoticeError.NOTICE_RECOVER_ROLLBACK,
            c.SQLITE_NOTICE_RBU => return NoticeError.NOTICE_RBU,
            else => return BaseError.NOTICE,
        },
        else => unreachable,
    }
}
