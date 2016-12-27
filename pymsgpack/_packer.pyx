# coding: utf-8
#cython: embedsignature=True

# 现在我们��? pymsgpack 支持简单的 Python 对象的序列化
# msgpack 中的 0xc1 类型保留无用，我们拿过来作为自定义的类型头前缀
# 我们的自定义头命名为 diy，第一个字节为 0xc1
# diy 的第二个字节表示子类型，定义如下��?
# 0x00: tuple
# 0x01: set (frozenset will be treated as set now)
# 0x10: object
# 外部沿用 msgpack.packb/unpackb 接口，因此不采用定义 default 函数的方法，而是在内部实现��?

from cpython cimport *

from pymsgpack.exceptions import PackValueError, PackOverflowError
from pymsgpack import ExtType


cdef extern from "Python.h":

    int PyMemoryView_Check(object obj)
    int PySet_Check(object obj)
    int PySet_CheckExact(object obj)

cdef extern from "pack.h":
    struct msgpack_packer:
        char* buf
        size_t length
        size_t buf_size
        bint use_bin_type

    int msgpack_pack_int(msgpack_packer* pk, int d)
    int msgpack_pack_nil(msgpack_packer* pk)
    int msgpack_pack_true(msgpack_packer* pk)
    int msgpack_pack_false(msgpack_packer* pk)
    int msgpack_pack_long(msgpack_packer* pk, long d)
    int msgpack_pack_long_long(msgpack_packer* pk, long long d)
    int msgpack_pack_unsigned_long_long(msgpack_packer* pk, unsigned long long d)
    int msgpack_pack_float(msgpack_packer* pk, float d)
    int msgpack_pack_double(msgpack_packer* pk, double d)
    int msgpack_pack_array(msgpack_packer* pk, size_t l)
    int msgpack_pack_tuple(msgpack_packer* pk, size_t l)
    int msgpack_pack_set(msgpack_packer* pk, size_t l)
    int msgpack_pack_object(msgpack_packer* pk)
    int msgpack_pack_map(msgpack_packer* pk, size_t l)
    int msgpack_pack_raw(msgpack_packer* pk, size_t l)
    int msgpack_pack_bin(msgpack_packer* pk, size_t l)
    int msgpack_pack_raw_body(msgpack_packer* pk, char* body, size_t l)
    int msgpack_pack_ext(msgpack_packer* pk, char typecode, size_t l)

cdef int DEFAULT_RECURSE_LIMIT=16
cdef size_t ITEM_LIMIT = (2**32)-1
cdef size_t MODULE_CLASS_NAME_LIMIT = 128


cdef class Packer(object):
    """
    MessagePack Packer

    usage::

        packer = Packer()
        astream.write(packer.pack(a))
        astream.write(packer.pack(b))

    Packer's constructor has some keyword arguments:

    :param callable default:
        Convert user type to builtin type that Packer supports.
        See also simplejson's document.
    :param str encoding:
        Convert unicode to bytes with this encoding. (default: 'utf-8')
    :param str unicode_errors:
        Error handler for encoding unicode. (default: 'strict')
    :param bool use_single_float:
        Use single precision float type for float. (default: False)
    :param bool autoreset:
        Reset buffer after each pack and return it's content as `bytes`. (default: True).
        If set this to false, use `bytes()` to get content and `.reset()` to clear buffer.
    :param bool use_bin_type:
        Use bin type introduced in msgpack spec 2.0 for bytes.
        It also enable str8 type for unicode.
    :param bool strict_types:
        If set to true, types will be checked to be exact. Derived classes
        from serializeable types will not be serialized and will be
        treated as unsupported type and forwarded to default.
        This is useful when trying to implement accurate serialization
        for python types.
    :param bool compatible_mode:
        If set to true, use pure msgpack protocol, so we don't support diy types (set, tuple, instance...) with this mode. 
        default False.
    """
    cdef msgpack_packer pk
    cdef object _default
    cdef object _bencoding
    cdef object _berrors
    cdef char *encoding
    cdef char *unicode_errors
    cdef bint strict_types
    cdef bint compatible_mode
    cdef bool use_float
    cdef bint autoreset

    def __cinit__(self):
        cdef int buf_size = 1024*1024
        self.pk.buf = <char*> PyMem_Malloc(buf_size)
        if self.pk.buf == NULL:
            raise MemoryError("Unable to allocate internal buffer.")
        self.pk.buf_size = buf_size
        self.pk.length = 0

    def __init__(self, default=None, encoding='utf-8', unicode_errors='strict',
                 use_single_float=False, bint autoreset=1, bint use_bin_type=0,
                 bint strict_types=0, bint compatible_mode=0):
        self.use_float = use_single_float
        self.strict_types = strict_types
        self.compatible_mode = compatible_mode
        self.autoreset = autoreset
        self.pk.use_bin_type = use_bin_type
        if default is not None:
            if not PyCallable_Check(default):
                raise TypeError("default must be a callable.")
        self._default = default
        if encoding is None:
            self.encoding = NULL
            self.unicode_errors = NULL
        else:
            if isinstance(encoding, unicode):
                self._bencoding = encoding.encode('ascii')
            else:
                self._bencoding = encoding
            self.encoding = PyBytes_AsString(self._bencoding)
            if isinstance(unicode_errors, unicode):
                self._berrors = unicode_errors.encode('ascii')
            else:
                self._berrors = unicode_errors
            self.unicode_errors = PyBytes_AsString(self._berrors)

    def __dealloc__(self):
        PyMem_Free(self.pk.buf)
        self.pk.buf = NULL

    cdef int _pack(self, object o, int nest_limit=DEFAULT_RECURSE_LIMIT) except -1:
        cdef long long llval
        cdef unsigned long long ullval
        cdef long longval
        cdef float fval
        cdef double dval
        cdef char* rawval
        cdef char* rawval2
        cdef int ret
        cdef dict d
        cdef size_t L
        cdef size_t mnl
        cdef size_t cnl
        cdef int default_used = 0
        cdef bint strict_types = self.strict_types
        cdef bint compatible_mode = self.compatible_mode
        cdef Py_buffer view

        if nest_limit < 0:
            raise PackValueError("recursion limit exceeded.")

        while True:
            if o is None:
                ret = msgpack_pack_nil(&self.pk)
            elif PyBool_Check(o) if strict_types else isinstance(o, bool):
                if o:
                    ret = msgpack_pack_true(&self.pk)
                else:
                    ret = msgpack_pack_false(&self.pk)
            elif PyLong_CheckExact(o) if strict_types else PyLong_Check(o):
                # PyInt_Check(long) is True for Python 3.
                # So we should test long before int.
                try:
                    if o > 0:
                        ullval = o
                        ret = msgpack_pack_unsigned_long_long(&self.pk, ullval)
                    else:
                        llval = o
                        ret = msgpack_pack_long_long(&self.pk, llval)
                except OverflowError as oe:
                    if not default_used and self._default is not None:
                        o = self._default(o)
                        default_used = True
                        continue
                    else:
                        raise PackOverflowError("Integer value out of range")
            elif PyInt_CheckExact(o) if strict_types else PyInt_Check(o):
                longval = o
                ret = msgpack_pack_long(&self.pk, longval)
            elif PyFloat_CheckExact(o) if strict_types else PyFloat_Check(o):
                if self.use_float:
                   fval = o
                   ret = msgpack_pack_float(&self.pk, fval)
                else:
                   dval = o
                   ret = msgpack_pack_double(&self.pk, dval)
            elif PyBytes_CheckExact(o) if strict_types else PyBytes_Check(o):
                L = len(o)
                if L > ITEM_LIMIT:
                    raise PackValueError("bytes is too large")
                rawval = o
                ret = msgpack_pack_bin(&self.pk, L)
                if ret == 0:
                    ret = msgpack_pack_raw_body(&self.pk, rawval, L)
            elif PyUnicode_CheckExact(o) if strict_types else PyUnicode_Check(o):
                if not self.encoding:
                    raise TypeError("Can't encode unicode string: no encoding is specified")
                o = PyUnicode_AsEncodedString(o, self.encoding, self.unicode_errors)
                L = len(o)
                if L > ITEM_LIMIT:
                    raise PackValueError("unicode string is too large")
                rawval = o
                ret = msgpack_pack_raw(&self.pk, L)
                if ret == 0:
                    ret = msgpack_pack_raw_body(&self.pk, rawval, L)
            elif PyDict_CheckExact(o):
                d = <dict>o
                L = len(d)
                if L > ITEM_LIMIT:
                    raise PackValueError("dict is too large")
                ret = msgpack_pack_map(&self.pk, L)
                if ret == 0:
                    for k, v in d.iteritems():
                        ret = self._pack(k, nest_limit-1)
                        if ret != 0: break
                        ret = self._pack(v, nest_limit-1)
                        if ret != 0: break
            elif not strict_types and PyDict_Check(o):
                L = len(o)
                if L > ITEM_LIMIT:
                    raise PackValueError("dict is too large")
                ret = msgpack_pack_map(&self.pk, L)
                if ret == 0:
                    for k, v in o.items():
                        ret = self._pack(k, nest_limit-1)
                        if ret != 0: break
                        ret = self._pack(v, nest_limit-1)
                        if ret != 0: break
            elif type(o) is ExtType if strict_types else isinstance(o, ExtType):
                # This should be before Tuple because ExtType is namedtuple.
                longval = o.code
                rawval = o.data
                L = len(o.data)
                if L > ITEM_LIMIT:
                    raise PackValueError("EXT data is too large")
                ret = msgpack_pack_ext(&self.pk, longval, L)
                ret = msgpack_pack_raw_body(&self.pk, rawval, L)
            elif PyList_CheckExact(o) if strict_types else PyList_Check(o):
                L = len(o)
                if L > ITEM_LIMIT:
                    raise PackValueError("list is too large")
                ret = msgpack_pack_array(&self.pk, L)
                if ret == 0:
                    for v in o:
                        ret = self._pack(v, nest_limit-1)
                        if ret != 0: break
            elif not compatible_mode and (PyTuple_CheckExact(o) if strict_types else PyTuple_Check(o)):
                L = len(o)
                if L > ITEM_LIMIT:
                    raise PackValueError("tuple is too large")
                ret = msgpack_pack_tuple(&self.pk, L)
                if ret == 0:
                    ret = msgpack_pack_array(&self.pk, L)
                if ret == 0:
                    for v in o:
                        ret = self._pack(v, nest_limit-1)
                        if ret != 0: break
            elif not compatible_mode and (PySet_CheckExact(o) if strict_types else PySet_Check(o)):
                L = len(o)
                if L > ITEM_LIMIT:
                    raise PackValueError("set is too large")
                ret = msgpack_pack_set(&self.pk, L)
                if ret == 0:
                    ret = msgpack_pack_array(&self.pk, L)
                if ret == 0:
                    for v in o:
                        ret = self._pack(v, nest_limit-1)
                        if ret != 0: break
            elif PyMemoryView_Check(o):
                if PyObject_GetBuffer(o, &view, PyBUF_SIMPLE) != 0:
                    raise PackValueError("could not get buffer for memoryview")
                L = view.len
                if L > ITEM_LIMIT:
                    PyBuffer_Release(&view);
                    raise PackValueError("memoryview is too large")
                ret = msgpack_pack_bin(&self.pk, L)
                if ret == 0:
                    ret = msgpack_pack_raw_body(&self.pk, <char*>view.buf, L)
                PyBuffer_Release(&view);
            elif not default_used and self._default:
                o = self._default(o)
                default_used = 1
                continue
            #elif PyInstance_Check(o) or isinstance(o, object):
            elif not compatible_mode and (PyInstance_Check(o) or (PyObject_IsInstance(o, object) and PyObject_HasAttr(o, "__dict__"))):
                mnl = len(o.__module__)
                cnl = len(o.__class__.__name__)
                d = <dict>o.__dict__
                L = len(d)
                if L > ITEM_LIMIT:
                    raise PackValueError("object is too large")
                if mnl >= MODULE_CLASS_NAME_LIMIT or cnl >= MODULE_CLASS_NAME_LIMIT or mnl <= 0 or cnl <= 0:
                    # we limit the name length to less than 128 to make sure the bin type is (0xc4)
                    raise PackValueError("module name or class name is too large" % (o.__module__, o.__class__.__name__))
                rawval = o.__module__
                rawval2 = o.__class__.__name__
                ret = msgpack_pack_object(&self.pk)
                msgpack_pack_bin(&self.pk, mnl);
                msgpack_pack_raw_body(&self.pk, rawval, mnl);
                msgpack_pack_bin(&self.pk, cnl);
                msgpack_pack_raw_body(&self.pk, rawval2, cnl);
                msgpack_pack_map(&self.pk, L);
                if ret == 0:
                    for k, v in d.iteritems():
                        ret = self._pack(k, nest_limit-1)
                        if ret != 0: break
                        ret = self._pack(v, nest_limit-1)
                        if ret != 0: break
            else:
                raise TypeError("can't serialize %r" % (o,))
            return ret

    cpdef pack(self, object obj):
        cdef int ret
        ret = self._pack(obj, DEFAULT_RECURSE_LIMIT)
        if ret == -1:
            raise MemoryError
        elif ret:  # should not happen.
            raise TypeError
        if self.autoreset:
            buf = PyBytes_FromStringAndSize(self.pk.buf, self.pk.length)
            self.pk.length = 0
            return buf

    def pack_ext_type(self, typecode, data):
        msgpack_pack_ext(&self.pk, typecode, len(data))
        msgpack_pack_raw_body(&self.pk, data, len(data))

    def pack_array_header(self, long long size):
        if size > ITEM_LIMIT:
            raise PackValueError
        cdef int ret = msgpack_pack_array(&self.pk, size)
        if ret == -1:
            raise MemoryError
        elif ret:  # should not happen
            raise TypeError
        if self.autoreset:
            buf = PyBytes_FromStringAndSize(self.pk.buf, self.pk.length)
            self.pk.length = 0
            return buf

    def pack_map_header(self, long long size):
        if size > ITEM_LIMIT:
            raise PackValueError
        cdef int ret = msgpack_pack_map(&self.pk, size)
        if ret == -1:
            raise MemoryError
        elif ret:  # should not happen
            raise TypeError
        if self.autoreset:
            buf = PyBytes_FromStringAndSize(self.pk.buf, self.pk.length)
            self.pk.length = 0
            return buf

    def pack_map_pairs(self, object pairs):
        """
        Pack *pairs* as msgpack map type.

        *pairs* should sequence of pair.
        (`len(pairs)` and `for k, v in pairs:` should be supported.)
        """
        cdef int ret = msgpack_pack_map(&self.pk, len(pairs))
        if ret == 0:
            for k, v in pairs:
                ret = self._pack(k)
                if ret != 0: break
                ret = self._pack(v)
                if ret != 0: break
        if ret == -1:
            raise MemoryError
        elif ret:  # should not happen
            raise TypeError
        if self.autoreset:
            buf = PyBytes_FromStringAndSize(self.pk.buf, self.pk.length)
            self.pk.length = 0
            return buf

    def reset(self):
        """Clear internal buffer."""
        self.pk.length = 0

    def bytes(self):
        """Return buffer content."""
        return PyBytes_FromStringAndSize(self.pk.buf, self.pk.length)