#lang racket/base
;; ============================================================
;; G1 防回归：bitfield 打包 + 多维数组
;;
;;   * C 位域无法用 define-cstruct 表达 → 一个存储单元打成一个底层整型字段
;;     （VkAccelerationStructureInstanceKHR -> _bits0/_bits1），另生成访问器
;;   * 多维数组必须保留所有维度（float matrix[3][4] -> (_array _float 3 4)）
;;
;; 用临时目录重跑生成器（只带 VK_KHR_acceleration_structure），断言生成物，
;; 并在子进程里加载生成的 ctype 对照 gcc 的 sizeof/alignof。
;; ============================================================

(require rackunit
         racket/system
         racket/file
         racket/string
         racket/path
         racket/port
         racket/runtime-path)

(define-runtime-path here ".")
(define-runtime-path probe-template "templates/bitfield-probe.rkt.tmpl")
(define-runtime-path check-template "templates/bitfield-check.c.tmpl")
(define project-root (simplify-path (build-path here "..")))
(define gen (build-path project-root "vulkan-gen" "main.rkt"))
(define reg (build-path project-root "registry" "vk-1.4.363.xml"))
(define out (make-temporary-file "vkbf-~a" 'directory))
(define audit (make-temporary-file "vkbf-audit-~a" 'directory))

(define (run-capture prog . args)
  (define o (open-output-string))
  (define code (parameterize ([current-output-port o])
                 (apply system*/exit-code prog args)))
  (values code (get-output-string o)))

(define racket-exe (find-executable-path "racket"))

(define (run-generator)
  (parameterize ([current-error-port (open-output-nowhere)])
    (system*/exit-code racket-exe (path->string gen) (path->string reg)
                       (path->string out) "VK_VERSION_1_4"
                       "VK_KHR_acceleration_structure" (path->string audit))))

(check-equal? (run-generator) 0 "generator should exit 0")

(define types (file->lines (build-path out "types.rkt")))
(define (has? s) (for/or ([l (in-list types)]) (string-contains? l s)))

;; 1. 多维数组保留全部维度
(check-true (has? "(define-cstruct _VkTransformMatrixKHR ((matrix (_array _float 3 4)")
            "multi-dim array must keep all dimensions")

;; 2. 位域按存储单元打包（24+8 / 24+8）
(check-true
 (has? (string-append
        "(define-cstruct _VkAccelerationStructureInstanceKHR "
        "((transform _VkTransformMatrixKHR) (_bits0 _uint32) (_bits1 _uint32) "
        "(accelerationStructureReference _uint64))"))
 "bitfields must pack into one field per storage unit")

;; 3. 每个具名位域都有 getter/setter；reserved 不生成
(for ([s '("VkAccelerationStructureInstanceKHR-instanceCustomIndex"
           "VkAccelerationStructureInstanceKHR-mask"
           "VkAccelerationStructureInstanceKHR-instanceShaderBindingTableRecordOffset"
           "VkAccelerationStructureInstanceKHR-flags")])
  (check-true (has? (format "(define (~a " s)) (format "getter generated: ~a" s))
  (check-true (has? (format "(define (set-~a! " s)) (format "setter generated: ~a" s)))
(check-false (has? "VkAccelerationStructureInstanceKHR-reserved")
             "reserved bitfields get no accessor")

;; 4. 子进程加载生成的 ctype，检查布局与位域读写（探针程序外置在模板文件）
(define probe (build-path out "probe.rkt"))
(copy-file probe-template probe #t)
(define-values (pcode pout) (run-capture racket-exe (path->string probe)))
(check-equal? pcode 0 (format "probe should run: ~a" pout))
(check-true (string-contains? pout "size=64 align=8 transform=48")
            (format "packed layout: ~a" pout))
(check-true (string-contains? pout "bits0=#x5aabcdef bits1=#xf000000 custom=#xabcdef mask=#x5a flags=#xf")
            (format "bitfield read/write: ~a" pout))

;; 5. gcc 对照（有 gcc + vulkan 头文件时）
(define gcc (find-executable-path "gcc"))
(define vulkan-h "/usr/include/vulkan/vulkan.h")
(when (and gcc (file-exists? vulkan-h))
  (define c (build-path out "bf.c"))
  (define exe (build-path out "bf"))
  (copy-file check-template c #t)
  (check-equal? (system*/exit-code gcc (path->string c) "-o" (path->string exe)) 0
                "gcc compile")
  (define-values (ccode cout) (run-capture (path->string exe)))
  (check-equal? ccode 0)
  (check-equal? (string-trim cout) "64 8 48" "C ABI matches packed layout"))

(delete-directory/files out)
(printf "bitfield: all checks passed\n")
