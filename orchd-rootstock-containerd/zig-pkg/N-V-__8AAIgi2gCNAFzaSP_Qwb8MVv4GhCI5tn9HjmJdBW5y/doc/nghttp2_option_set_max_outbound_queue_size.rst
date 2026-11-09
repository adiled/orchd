
nghttp2_option_set_max_outbound_queue_size
==========================================

Synopsis
--------

*#include <nghttp2/nghttp2.h>*

.. function:: void nghttp2_option_set_max_outbound_queue_size(nghttp2_option *option, size_t val)

    
    This function sets the maximum number of frames allowed in the
    outbound queue.  The limit is checked after
    `nghttp2_session_mem_recv2()` and `nghttp2_session_recv()`.  The
    current queue size (excluding deferred DATA frames) can be obtained
    by `nghttp2_session_get_outbound_queue_size()`.  If it exceeds
    *val*, `nghttp2_session_mem_recv2()` and `nghttp2_session_recv()`
    return :enum:`nghttp2_error.NGHTTP2_ERR_FLOODED`.  The default
    value is 5000.
