#lang racket/base
(require ffi/unsafe ffi/unsafe/define ffi/vector)
(define-ffi-definer define-libc (ffi-lib #f))
;; qsort(void*, size_t, size_t, int(*)(const void*, const void*))
(define-libc qsort (_fun _pointer _size _size (_fun _pointer _pointer -> _int) -> _void))
(define v (s32vector 5 3 1 4 2))
(define cmp (lambda (a b) (- (ptr-ref a _int32) (ptr-ref b _int32))))
(qsort (s32vector->cpointer v) 5 4 cmp)
(printf "sorted: ~a\n" (build-list 5 (λ (i) (s32vector-ref v i))))
