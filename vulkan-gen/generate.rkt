#lang racket/base
;; ============================================================
;; 生成层：`vk-model` -> `vk-artifact`（模块三部分：依赖 / 模块体 / 导出）。
;;
;; 只消费 vk-model（不再回看 registry/ctype），因此可脱离 XML 单测。
;; 生成按领域分类拆开，互不引用：
;;   预定义常量 generate-constants   （constants.rkt）
;;   枚举       generate-enums       （types.rkt 的 enum 部分）
;;   结构体     generate-structs     （types.rkt 的 struct/union 部分）
;;   函数       generate-functions   （commands.rkt）
;; 另有 other-types（handle/bitmask/basetype/funcpointer/alias）。
;; ============================================================

(require racket/list
         racket/string
         racket/runtime-path
         vulkan/api-facts
         "model.rkt"
         "constants.rkt"
         "emit-types.rkt"
         "emit-commands.rkt"
         "emit-pnext.rkt"
         "emit-safe.rkt"
         "emit-api.rkt"
         "emit-version.rkt"
         "classify.rkt"
         "module.rkt"
         "template.rkt")

(define-runtime-path abi-template "templates/abi_check.c.tmpl")

(provide generate-artifacts
         generate-constants
         generate-enums
         generate-structs
         generate-other-types
         generate-types
         generate-functions
         generate-abi-c)

;; ---------------- 四类领域入口（各返回本领域的 vk-type / 形式）----------------

;; 预定义常量（枚举成员 / #define / 扩展常量）-> (define NAME VAL)
(define (generate-constants model)
  (constant-forms (vk-model-constants model)))

(define (generate-enums model) (vk-model-enums model))
(define (generate-structs model) (vk-model-structs model))
(define (generate-other-types model) (vk-model-other-types model))

(define (generate-functions model)
  (command-forms (vk-model-functions model)))

;; types.rkt：每个类型恰好经一个领域入口，最后按拓扑序重排
;; （alias 目标必须先定义；所以不能直接拼接三个类别）。
(define (generate-types model)
  (define all (append (generate-enums model)
                      (generate-structs model)
                      (generate-other-types model)))
  (define forms (for/hasheqv ([t (in-list all)])
                  (values (vk-type-name t) (type-form t))))
  (append* (for/list ([t (in-list (vk-model-types model))])
             (hash-ref forms (vk-type-name t)))))

;; ---------------- 审计：ABI 对照 C 程序（仅 core struct/union）----------------
;; 模板外置在 templates/abi_check.c.tmpl，这里只填 SZ 行。
(define (generate-abi-c model)
  (define feat-types (vk-model-feat-types model))
  (define cats (for/hasheqv ([t (in-list (vk-model-types model))])
                 (values (vk-type-name t) (vk-type-category t))))
  (define names
    (for/list ([nm (in-list (vk-model-wanted-list model))]
               #:when (and (member (symbol->string nm) feat-types)
                           (memq (hash-ref cats nm #f) '(struct union))))
      nm))
  (define sz-lines
    (apply string-append (for/list ([nm (in-list names)]) (format "  SZ(~a);\n" nm))))
  (fill-template (read-template abi-template) (list (cons "SZ_LINES" sz-lines))))

;; ---------------- 组装所有产物 ----------------

;; `#:registry-file` 是 driver 才知道的信息（生成所用文件名），故作为参数传入。
(define (generate-artifacts model #:registry-file registry-file #:diags [diags #f])
  (define types (vk-model-types model))
  (define cmds (vk-model-commands model))
  ;; 不静默：每条没有干净糖形状的命令都记录为 info（仍保留 raw 命令）
  (for ([c (in-list cmds)])
    (when (eq? (vk-plan-shape (classify-command c)) 'skip)
      (diagnose! diags 'info 'safe (vk-command-name c)
                 "no clean sugar shape; raw command only")))
  (define safe-forms (filter values (emit-safe-forms cmds)))
  (list
   (make-artifact "constants.rkt"
                  (make-module #:exports '((all-defined-out)) (generate-constants model)))
   (make-artifact "types.rkt"
                  (make-module #:deps '(ffi/unsafe ffi/unsafe/define "constants.rkt")
                               #:exports '((all-defined-out))
                               (generate-types model)))
   (make-artifact "commands.rkt"
                  (make-module #:deps '(ffi/unsafe vulkan/base)
                               #:exports '((all-defined-out))
                               (generate-functions model)))
   (make-artifact "safe.rkt"
                  (make-module #:deps '(ffi/unsafe vulkan/base
                                               (prefix-in raw: vulkan/commands)
                                               vulkan/memory vulkan/result
                                               vulkan/context vulkan/safe-support)
                               #:exports '((all-defined-out))
                               safe-forms))
   (make-artifact "pnext.rkt"
                  (make-module #:deps '("constants.rkt" "types.rkt")
                               #:exports '((all-defined-out)) (pnext-forms types)))
   (make-artifact "facts.rkt"     (facts-module cmds) render-facts)
   (make-artifact "version.rkt"
                  (version-module #:binding-version (vk-model-version model)
                                  #:registry-file registry-file
                                  #:feature (vk-model-feature model)
                                  #:extensions (vk-model-ext-closure model))
                  render-version)))
