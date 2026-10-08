#lang racket/base
;; ============================================================
;; generated/facts.rkt 的**模块体**：vk-command 事实 -> datum 列表。
;;
;; 模块三部分（依赖 / 模块体 / 导出）由 module.rkt 描述；把 datum 包成
;; `(define vk-command-facts (list ...))` 的写出属于「逻辑输出」，
;; 见 render-facts（与旧产物逐字节一致）。
;; ============================================================

(require racket/runtime-path
         vulkan/api-facts
         "module.rkt"
         "template.rkt")

(define-runtime-path facts-template "templates/facts.rkt.tmpl")

(provide command->datum
         facts-module
         render-facts)

;; vk-command -> 可写出的 datum
(define (command->datum c)
  `(vk-command ',(vk-command-name c) ',(vk-command-level c)
               ,(vk-command-result? c)
               ,(vk-command-dispatch c)
               (list ,@(map (λ (p)
                              `(vk-param ',(vk-param-name p) ,(vk-param-base p)
                                         ',(vk-param-ctype p)
                                         ,(vk-param-pointer? p) ,(vk-param-const? p)
                                         ,(vk-param-count? p) ',(vk-param-kind p)
                                         ,(vk-param-output? p) ,(vk-param-flat? p)))
                            (vk-command-params c)))
               ',(vk-command-count-field c)))

;; 依赖：运行期 IR 结构体；导出：IR 结构体 + 事实表；模块体：命令 datum 列表。
(define (facts-module commands)
  (make-module
   #:deps '(vulkan/api-facts)
   #:exports '((all-from-out vulkan/api-facts) vk-command-facts)
   (map command->datum commands)))

;; 输出：完整模块（事实表按命令一行一个 datum，避免超长行；骨架来自模板文件）。
(define (render-facts mod port)
  (define datums
    (let ([o (open-output-string)])
      (for ([c (in-list (vk-module-body mod))])
        (display "    " o) (write c o) (newline o))
      (get-output-string o)))
  (display (fill-template (read-template facts-template)
                          (list (cons "DATUMS" datums)))
           port))
