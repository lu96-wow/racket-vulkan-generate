#lang racket/base
;; ============================================================
;; M4：ABI 对照（sizeof / alignof）
;;
;; 用 gcc 编译 generated/abi_check.c（core struct/union），
;; 把 C 的 sizeof/_Alignof 与 Racket ctype 的 ctype-sizeof/ctype-alignof 逐一比对。
;;
;; 说明：Racket 不暴露 cstruct 字段偏移（define-cstruct 的 offset 绑定是
;; hygienic 的），故对照 size+align；二者足以捕获布局/类型宽度/位域错误。
;; ============================================================

(require rackunit
         racket/file
         racket/string
         racket/port
         racket/system
         racket/runtime-path
         racket/match
         ffi/unsafe)

(define-runtime-path here ".")
(define cfile (build-path here ".." "vulkan-gen" "audit" "abi_check.c"))

(define gcc (find-executable-path "gcc"))
(define headers? (file-exists? "/usr/include/vulkan/vulkan.h"))

(if (and gcc headers? (file-exists? cfile))
    (let* ([exe (build-path (find-system-path 'temp-dir) "racket-vulkan-abi-check")]
           [ok (parameterize ([current-error-port (open-output-nowhere)])
                 (system* gcc "-O0" "-o" (path->string exe) (path->string cfile)))])
      (check-true ok "gcc compiles abi_check.c")
      (define-values (proc out _in _err) (subprocess #f #f #f (path->string exe)))
      (define text (port->string out))
      (subprocess-wait proc)
      (when (file-exists? exe) (delete-file exe))
      (define checked (box 0))
      (for ([line (in-list (string-split text "\n"))] #:unless (string=? line ""))
        (match (string-split line)
          [(list "S" name size align)
           (define ct (dynamic-require 'vulkan/bindings (string->symbol (format "_~a" name))))
           (check-equal? (ctype-sizeof ct) (string->number size) (format "sizeof ~a" name))
           (check-equal? (ctype-alignof ct) (string->number align) (format "alignof ~a" name))
           (set-box! checked (add1 (unbox checked)))]
          [_ (void)]))
      (check-true (> (unbox checked) 300) "checked a meaningful number of structs")
      (printf "abi: ~a core struct/union sizes+alignments match gcc\n" (unbox checked)))
    (printf "abi: skipped (need gcc + /usr/include/vulkan/vulkan.h + generated/abi_check.c)\n"))
