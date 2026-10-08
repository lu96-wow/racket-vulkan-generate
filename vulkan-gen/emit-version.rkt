#lang racket/base
;; ============================================================
;; generated/version.rkt 的**模块体**：绑定版本 + provenance。
;;
;; 只 4 个字段，尽量简单可靠：
;;   vk-binding-version      "1.4.363"        绑定/包版本（= 注册表版本）
;;   vk-registry-file        "vk-1.4.363.xml" 生成所用注册表文件
;;   vk-generated-feature    "VK_VERSION_1_4" 目标 feature
;;   vk-generated-extensions '("VK_KHR_surface" ...) 纳入的扩展闭包（已排序）
;;
;; 模块三部分由 module.rkt 描述；写出见 render-version。
;; ============================================================

(require racket/list
         racket/runtime-path
         "module.rkt"
         "template.rkt")

(define-runtime-path version-template "templates/version.rkt.tmpl")

(provide version-module
         render-version)

(define (version-module #:binding-version binding-version
                        #:registry-file registry-file
                        #:feature feature
                        #:extensions extensions)
  (define exts (sort (for/list ([e (in-list extensions)])
                       (if (symbol? e) (symbol->string e) e))
                     string<?))
  (make-module
   #:exports '(vk-binding-version vk-registry-file
               vk-generated-feature vk-generated-extensions)
   (list `(define vk-binding-version ,(or binding-version "unknown"))
         `(define vk-registry-file ,(or registry-file "unknown"))
         `(define vk-generated-feature ,feature)
         `(define vk-generated-extensions (quote ,exts)))))

;; 输出：完整模块；骨架与字段来自模板文件。
(define (render-version mod port)
  (define body (vk-module-body mod))
  (define (value name)
    (for/first ([f (in-list body)]
                #:when (and (pair? f) (eq? (car f) 'define) (eq? (cadr f) name)))
      (caddr f)))
  (define exts (cadr (value 'vk-generated-extensions)))
  (display (fill-template (read-template version-template)
                          (list (cons "BINDING_VERSION" (format "~s" (value 'vk-binding-version)))
                                (cons "REGISTRY_FILE"   (format "~s" (value 'vk-registry-file)))
                                (cons "FEATURE"         (format "~s" (value 'vk-generated-feature)))
                                (cons "EXTENSIONS"      (format "~s" exts))))
           port))
