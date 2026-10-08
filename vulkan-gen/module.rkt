#lang racket/base
;; ============================================================
;; 目标 Racket 模块的三部分：**模块依赖 / 模块体 / 导出**。
;;
;; 生成层只产出 `vk-module`（三部分是纯数据，不含写出方式）；写出是另一部分，
;; 由 `vk-artifact` 携带的 render 过程完成：
;;
;;   * `.inc` 产物：只把 **模块体** 交给 include 它的手写模块
;;     （`base.rkt` / `commands.rkt` / `safe.rkt`），依赖与导出由该模块提供。
;;     三部分仍如实记录，便于审计。
;;   * `.rkt` 产物：自带依赖/导出，用 `default-render` 写出完整模块。
;;
;;   deps    : (listof require-spec)
;;   body    : (listof form)
;;   exports : (listof provide-spec)
;; ============================================================

(require racket/list
         racket/pretty
         racket/runtime-path
         "template.rkt")

(define-runtime-path module-template "templates/module.rkt.tmpl")

(provide (struct-out vk-module)
         (struct-out vk-artifact)
         make-module
         make-artifact
         default-render
         write-module-body
         write-artifact)

(struct vk-module (deps body exports) #:transparent)

;; render : (-> vk-module output-port? void?)
(struct vk-artifact (name module render) #:transparent)

(define (make-module #:deps [deps '()] #:exports [exports '()] body)
  (vk-module deps body exports))

(define (make-artifact name mod [render default-render])
  (vk-artifact name mod render))

;; 只写模块体（`.inc`：被手写模块 include）。
(define (write-module-body mod port)
  (for ([f (in-list (vk-module-body mod))])
    (write f port)
    (newline port)))

;; 完整模块： #lang racket/base + 依赖 + 模块体 + 导出
(define (form->string f)
  (define o (open-output-string))
  (parameterize ([print-as-expression #f]) (pretty-print f o))
  (get-output-string o))

;; 骨架来自模板文件 templates/module.rkt.tmpl
(define (default-render mod port)
  (define requires
    (if (null? (vk-module-deps mod)) ""
        (string-append (format "~s" (cons 'require (vk-module-deps mod))) "\n")))
  (define body (apply string-append (map form->string (vk-module-body mod))))
  (define provides
    (if (null? (vk-module-exports mod)) ""
        (string-append (format "~s" (cons 'provide (vk-module-exports mod))) "\n")))
  (display (fill-template (read-template module-template)
                          (list (cons "REQUIRES" requires)
                                (cons "BODY" body)
                                (cons "PROVIDES" provides)))
           port))

(define (write-artifact art path)
  (call-with-output-file path #:exists 'replace
    (λ (o) ((vk-artifact-render art) (vk-artifact-module art) o))))
