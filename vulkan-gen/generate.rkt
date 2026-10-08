#lang racket/base
;; ============================================================
;; 生成层：`vk-model` -> `vk-artifact`（模块三部分：依赖 / 模块体 / 导出）。
;;
;; 生成按领域分类拆开，互不引用：
;;   预定义常量 generate-constants   （constants.inc）
;;   枚举       generate-enums       （types.inc 的 enum 部分）
;;   结构体     generate-structs     （types.inc 的 struct/union 部分）
;;   函数       generate-functions   （commands.inc）
;; 另有 other-types（handle/bitmask/basetype/funcpointer/alias）。
;;
;; 注意：types.inc 必须按 by-value 依赖顺序，所以整表用 generate-types
;; （= model 的拓扑序）交错生成；分类函数用于审计/复用，不改变整体顺序。
;; ============================================================

(require racket/list
         racket/string
         racket/runtime-path
         "vk-registry.rkt"
         "ctype.rkt"
         "constants.rkt"
         "emit-types.rkt"
         "emit-commands.rkt"
         "emit-pnext.rkt"
         "emit-safe.rkt"
         "emit-api.rkt"
         "emit-version.rkt"
         "classify.rkt"
         "parse.rkt"
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

(define (reg-of model) (vk-model-registry model))

;; ---------------- 四类领域生成 ----------------

;; 预定义常量（枚举成员 / #define / 扩展常量）-> (define NAME VAL)
(define (generate-constants model)
  (constant-forms (vk-model-constants model)))

(define (generate-enums model)
  (type-forms (reg-of model) (vk-model-enums model)))

(define (generate-structs model)
  (type-forms (reg-of model) (vk-model-structs model)))

;; 结构体之外的绑定类型（handle / bitmask / basetype / funcpointer / alias）
(define (generate-other-types model)
  (type-forms (reg-of model) (vk-model-other-types model)))

;; 交错顺序（types.inc 用）：enum + struct + other 按拓扑序输出
(define (generate-types model)
  (type-forms (reg-of model) (vk-model-types model)))

;; 函数（命令）-> (define-vk ...)
(define (generate-functions model)
  (command-forms (reg-of model) (vk-model-wanted-cmds model)))

;; ---------------- 审计：ABI 对照 C 程序（仅 core struct/union）----------------
;; 模板外置在 templates/abi_check.c.tmpl，这里只填 SZ 行。
(define (generate-abi-c model)
  (define reg (reg-of model))
  (define feat-types (vk-model-feat-types model))
  (define names
    (for/list ([nm (in-list (vk-model-wanted-list model))]
               #:when (and (member (symbol->string nm) feat-types)
                           (memq (category-of reg nm) '(struct union))))
      nm))
  (define sz-lines
    (apply string-append (for/list ([nm (in-list names)]) (format "  SZ(~a);\n" nm))))
  (fill-template (read-template abi-template) (list (cons "SZ_LINES" sz-lines))))

;; ---------------- 组装所有产物 ----------------

;; `#:registry-file` 是 driver 才知道的信息（生成所用文件名），故作为参数传入。
(define (generate-artifacts model #:registry-file registry-file)
  (define reg (reg-of model))
  (define types (vk-model-types model))
  (define cmds (vk-model-commands model))
  (define safe-forms (filter values (emit-safe-forms cmds)))
  (list
   (make-artifact "constants.inc" (make-module (generate-constants model)) write-module-body)
   (make-artifact "types.inc"     (make-module (generate-types model)) write-module-body)
   (make-artifact "commands.inc"  (make-module (generate-functions model)) write-module-body)
   (make-artifact "safe.inc"      (make-module safe-forms) write-module-body)
   (make-artifact "pnext.inc"     (make-module (pnext-forms reg types)) write-module-body)
   (make-artifact "facts.rkt"     (facts-module cmds) render-facts)
   (make-artifact "version.rkt"
                  (version-module #:binding-version (registry-version reg)
                                  #:registry-file registry-file
                                  #:feature (vk-model-feature model)
                                  #:extensions (vk-model-ext-closure model))
                  render-version)))
