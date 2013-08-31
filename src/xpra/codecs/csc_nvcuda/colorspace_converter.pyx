# This file is part of Xpra.
# Copyright (C) 2013 Arthur Huillet
# Copyright (C) 2013 Antoine Martin <antoine@devloop.org.uk>
# Xpra is released under the terms of the GNU GPL v2, or, at your option, any
# later version. See the file COPYING for details.

import time
from xpra.codecs.codec_constants import codec_spec, get_subsampling_divs
from xpra.codecs.image_wrapper import ImageWrapper

cdef extern from "stdlib.h":
    void free(void *ptr)

cdef extern from "Python.h":
    ctypedef int Py_ssize_t
    ctypedef object PyObject
    object PyBuffer_FromMemory(void *ptr, Py_ssize_t size)
    int PyObject_AsReadBuffer(object obj, void ** buffer, Py_ssize_t * buffer_len) except -1

ctypedef unsigned char uint8_t
ctypedef void csc_nvcuda_ctx
cdef extern from "csc_nvcuda.h":
#char **get_supported_colorspaces()

    int init_cuda()
    csc_nvcuda_ctx *init_csc(int src_width, int src_height, const char *src_format, const char *dst_format)
    void free_csc(csc_nvcuda_ctx *ctx)
    int csc_image(csc_nvcuda_ctx *ctx, const uint8_t *input_image[3], const int in_stride[3], uint8_t *out[3], int out_stride[3]) nogil
    void free_csc_image(uint8_t *buf[3])
    char *get_NPP_version()


_init = None
def init():
    global _init
    if _init is None:
        _init = init_cuda()==0
    return _init
init()

COLORSPACES_SRC = [ "RGB", "RGBA", "BGR", "BGRX" ]
COLORSPACES_DST = [ "YUV420P", "YUV422P", "YUV444P" ]

def get_version():
    return get_NPP_version()

def get_input_colorspaces():
    if not init():
        return []
    return COLORSPACES_SRC

def get_output_colorspaces(input_colorspace):
    if not init():
        return []
    #exclude input colorspace:
    return COLORSPACES_DST

def get_spec(in_colorspace, out_colorspace):
    assert init(), "nvcuda is not available!"
    assert in_colorspace in COLORSPACES_SRC, "invalid input colorspace: %s (must be one of %s)" % (in_colorspace, COLORSPACES_SRC)
    assert out_colorspace in COLORSPACES_DST, "invalid output colorspace: %s (must be one of %s)" % (out_colorspace, COLORSPACES_DST)
    #ratings: quality, speed, setup cost, cpu cost, gpu cost, latency, max_w, max_h, max_pixels
    return codec_spec(ColorspaceConverter, speed=100, setup_cost=10, cpu_cost=10, gpu_cost=50, min_w=16, min_h=16, can_scale=False)


cdef class CSCImage:
    """
        Allows us to call free_csc_image
        when this object is garbage collected
    """
    cdef uint8_t *buf[3]
    cdef int freed

    cdef set_plane(self, int plane, uint8_t *buf):
        assert plane in (0, 1, 2)
        self.buf[plane] = buf

    def __dealloc__(self):
        #print("CSCImage.__dealloc__() calling free()")
        self.free()

    def free(self):
        #print("CSCImage.free() free_csc_image(..) already? %s" % self.freed)
        if self.freed==0:
            self.freed = 1
            free_csc_image(self.buf)


class CSCImageWrapper(ImageWrapper):

    def free(self):                             #@DuplicatedSignature
        #print("YUVImageWrapper.free() csc_image=%s" % self.csc_image)
        if self.csc_image:
            self.csc_image.free()
            self.csc_image = None

cdef class ColorspaceConverter:
    cdef int frames
    cdef csc_nvcuda_ctx *context
    cdef int src_width
    cdef int src_height
    cdef char* src_format
    cdef int dst_width
    cdef int dst_height
    cdef char* dst_format
    cdef double time

    def init_context(self, int src_width, int src_height, src_format,
                           int dst_width, int dst_height, dst_format, int speed=100):    #@DuplicatedSignature
        self.src_width = src_width
        self.src_height = src_height
        self.dst_width = dst_width
        self.dst_height = dst_height
        self.time = 0
        #ugly trick to use a string which won't go away from underneath us:
        assert src_format in COLORSPACES_SRC, "invalid source format: %s" % src_format
        for x in COLORSPACES_SRC:
            if x==src_format:
                self.src_format = x
                break
        assert dst_format in COLORSPACES_DST, "invalid destination format: %s" % dst_format
        for x in COLORSPACES_DST:
            if x==dst_format:
                self.dst_format = x
                break
        self.frames = 0
        self.context = init_csc(self.src_width, self.src_height, self.src_format, self.dst_format)

    def get_info(self):
        info = {"frames"    : self.frames,
                "src_width" : self.src_width,
                "src_height": self.src_height,
                "src_format": self.src_format,
                "dst_width" : self.dst_width,
                "dst_height": self.dst_height,
                "dst_format": self.dst_format}
        if self.frames>0 and self.time>0:
            pps = float(self.src_width) * float(self.src_height) * float(self.frames) / self.time
            info["total_time_ms"] = int(self.time*1000.0)
            info["pixels_per_second"] = int(pps)
        return info

    def __str__(self):
        return "nvcuda(%s %sx%s - %s %sx%s)" % (self.src_format, self.src_width, self.src_height,
                                                 self.dst_format, self.dst_width, self.dst_height)

    def __dealloc__(self):                  #@DuplicatedSignature
        self.clean()

    def get_src_width(self):
        return self.src_width

    def get_src_height(self):
        return self.src_height

    def get_src_format(self):
        return self.src_format

    def get_dst_width(self):
        return self.dst_width

    def get_dst_height(self):
        return self.dst_height

    def get_dst_format(self):
        return self.dst_format

    def get_type(self):
        return  "nvcuda"


    def clean(self):                        #@DuplicatedSignature
        if self.context!=NULL:
            free_csc(self.context)
            free(self.context)
            self.context = NULL

    def convert_image(self, image):
        cdef Py_ssize_t pic_buf_len = 0
        assert self.context!=NULL
        cdef const uint8_t *input_image[3]
        cdef uint8_t *output_image[3]
        cdef int input_stride[3]
        cdef int output_stride[3]
        cdef int planes
        cdef int i                          #@DuplicatedSignature
        cdef int height
        cdef int stride
        cdef int result
        planes = image.get_planes()
        assert planes in (0, 1, 3), "invalid number of planes: %s" % planes
        input = image.get_pixels()
        strides = image.get_rowstride()
        if planes==0:
            #magic: if planes==0, this is an XImageWrapper... with raw pixels/rowstride
            input = [input]
            strides = [strides]
            planes = 1
        #print("convert_image(%s) input=%s, strides=%s" % (image, len(input), strides))
        assert len(input)==planes, "expected %s planes but found %s" % (planes, len(input))
        assert len(strides)==planes, "expected %s rowstrides but found %s" % (planes, len(strides))
        for i in range(planes):
            input_stride[i] = strides[i]
            PyObject_AsReadBuffer(input[i], <const void**> &input_image[i], &pic_buf_len)
        start = time.time()
        with nogil:
            result = csc_image(self.context, input_image, input_stride, output_image, output_stride)
        if result != 0:
            return None
        end = time.time()
        self.time += (end-start)
        self.frames += 1
        #now parse the output:
        csci = CSCImage()           #keep a reference to memory for cleanup
        if self.dst_format.endswith("P"):
            nplanes = 3
            divs = get_subsampling_divs(self.dst_format)
            #print("convert_image(%s) nplanes=%s, divs=%s" % (image, nplanes, divs))
            out = []
            strides = []
            for i in range(nplanes):
                _, dy = divs[i]
                if dy==1:
                    height = self.dst_height
                elif dy==2:
                    height = (self.dst_height+1)>>1
                else:
                    raise Exception("invalid height divisor %s" % dy)
                stride = output_stride[i]
                if stride>0 and output_image[i]!=NULL:
                    plane = PyBuffer_FromMemory(<void *>output_image[i], height * stride)
                else:
                    stride = 0
                    plane = None
                csci.set_plane(i, output_image[i])
                out.append(plane)
                strides.append(stride)
        else:
            nplanes = 0
            strides = output_stride[0]
            out = PyBuffer_FromMemory(<void *>output_image[0], self.dst_height * strides)
            csci.set_plane(0, output_image[0])
        out_image = CSCImageWrapper(0, 0, self.dst_width, self.dst_height, out, self.dst_format, 24, strides, nplanes)
        out_image.csc_image = csci
        return out_image
