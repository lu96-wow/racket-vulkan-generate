#lang racket/base
;; ============================================================
;; 目标 Racket 模块的三部分：**模块依赖 / 模块体 / 导出**。
;;
;; 生成层只产出 `vk-module`（三部分是纯数据，不含写出方式）；写出是另一部分，
;; 由 `vk-artifact` 携带的 render 过程完成。
;;
;; 所有产物都是**真模块**（`#lang racket/base` + requires + body + provide），
;; 运行期用 `require`（不再是 `include`）。`default-render` 用模板文件
;; `templates/module.rkt.tmpl` 组装；body 一行一个 form。
;;
;;   deps    : (listof require-spec)
;;   body    : (listof form)
;;   exports : (listof provide-spec)
;; ============================================================

(require racket/list
         racket/runtime-path
         "template.rkt")

(define-runtime-path module-template "templates/module.rkt.tmpl")

(provide (struct-out vk-module)
         (struct-out vk-artifact)
         make-module
         make-artifact
         default-render
         artifact->string
         write-artifact
         write-file/atomic)

(struct vk-module (deps body exports) #:transparent)

;; render : (-> vk-module output-port? void?)
(struct vk-artifact (name module render) #:transparent)

(define (make-module #:deps [deps '()] #:exports [exports '()] body)
  (vk-module deps body exports))

(define (make-artifact name mod [render default-render])
  (vk-artifact name mod render))

;; 单个 form -> 一行文本（body 用）。
(define (form->string f)
  (define o (open-output-string))
  (write f o)
  (newline o)
  (get-output-string o))

;; 完整模块： #lang racket/base + 依赖 + 模块体 + 导出（骨架来自模板文件）
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

;; 渲染到字符串：先全部渲染成功，再落盘 -> 生成失败不会留下半套产物。
(define (artifact->string art)
  (define o (open-output-string))
  ((vk-artifact-render art) (vk-artifact-module art) o)
  (get-output-string o))

;; 原子写：先写 .tmp 再 rename。
(define (write-file/atomic path str)
  (define tmp (string-append (path->string path) ".tmp"))
  (call-with-output-file tmp #:exists 'replace (λ (o) (write-string str o)))
  (rename-file-or-directory tmp path #t))

(define (write-artifact art path)
  (write-file/atomic path (artifact->string art)))
