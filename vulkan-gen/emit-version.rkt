#lang racket/base
;; ============================================================
;; generated/version.rkt：绑定版本 + provenance（供运行期自省 / 测试）。
;;
;; 只 4 个字段，尽量简单可靠：
;;   vk-binding-version      "1.4.363"      绑定/包版本（= 注册表版本）
;;   vk-registry-file        "vk-1.4.363.xml" 生成所用注册表文件
;;   vk-generated-feature    "VK_VERSION_1_4" 目标 feature
;;   vk-generated-extensions '("VK_KHR_surface" ...) 纳入的扩展闭包（已排序）
;; ============================================================

(require racket/list)

(provide write-version-module)

(define (write-version-module path
                              #:binding-version binding-version
                              #:registry-file registry-file
                              #:feature feature
                              #:extensions extensions)
  (define exts (sort (for/list ([e (in-list extensions)])
                       (if (symbol? e) (symbol->string e) e))
                     string<?))
  (call-with-output-file path #:exists 'replace
    (λ (o)
      (display "#lang racket/base\n" o)
      (display ";; 自动生成（vulkan-gen）：绑定版本 / provenance。不要手改。\n" o)
      (display "(provide vk-binding-version vk-registry-file\n" o)
      (display "         vk-generated-feature vk-generated-extensions)\n\n" o)
      (fprintf o "(define vk-binding-version ~s)\n" (or binding-version "unknown"))
      (fprintf o "(define vk-registry-file ~s)\n" (or registry-file "unknown"))
      (fprintf o "(define vk-generated-feature ~s)\n" feature)
      (fprintf o "(define vk-generated-extensions\n  '~s)\n" exts))))
