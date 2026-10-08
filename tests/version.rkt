#lang racket/base
;; ============================================================
;; 版本 / provenance 回归：
;;   * 包版本（info.rkt）== 生成物 vk-binding-version
;;   * vk-registry-file / vk-generated-feature / extensions 与默认配方一致
;; ============================================================

(require rackunit
         racket/file
         racket/list
         racket/string
         racket/runtime-path
         vulkan
         (only-in vulkan-gen/extension-select common-extensions))

(define-runtime-path here ".")
(define root (simplify-path (build-path here "..")))

(define (info-version)
  (define m (regexp-match #px"\\(define version \"([^\"]+)\""
                          (file->string (build-path root "info.rkt"))))
  (and m (cadr m)))

(check-equal? (info-version) "1.4.363" "info.rkt version")
(check-equal? vk-binding-version (info-version)
              "generated vk-binding-version must equal package version")
(check-equal? vk-registry-file (format "vk-~a.xml" vk-binding-version))
(check-equal? vk-generated-feature "VK_VERSION_1_4")
(check-true (and (member "VK_KHR_surface" vk-generated-extensions) #t))
(check-true (and (member "VK_EXT_debug_utils" vk-generated-extensions) #t))
;; 默认构建的扩展闭包 == common 集
(check-equal? (sort vk-generated-extensions string<?)
              (sort common-extensions string<?))

(printf "version: all checks passed\n")
