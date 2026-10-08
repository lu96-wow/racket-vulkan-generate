#lang racket/base
;; ============================================================
;; 生成器的领域模型（解析层的输出 / 生成层的输入）。
;;
;; 局部化原则：`vk-model` 自足——生成层只看它，不再回看 registry 或
;; ctype 这些解析期输入。每个领域记录只装「事实」：
;;
;;   vk-diagnostic  降级/丢弃的可归因记录（领域 + 实体 + 原因）
;;   vk-type        一个绑定类型的归一事实（类别 + 生成所需 slot）
;;   vk-func        一个命令的绑定事实（define-vk 所需：level/arity/_fun）
;;   vk-model       选择结果 + 四个领域的记录表
;;
;; `vk-model` 不含 registry：需要的信息在解析期全部算好。`vulkan-gen/generate`
;; 因此可以脱离 XML 单测。
;; ============================================================

(provide (struct-out vk-diagnostic)
         (struct-out vk-diagnostics)
         make-diagnostics
         diagnose!
         diagnostics-list
         (struct-out vk-cfield)
         (struct-out vk-bitgroup)
         (struct-out vk-type)
         (struct-out vk-func)
         (struct-out vk-model))

;; ---------------- 诊断 ----------------
;; level  : 'info | 'warn | 'error
;; domain : 'type | 'constant | 'command | 'safe | 'module | 'output
;; entity : 具体名字（symbol/string）
;; reason : 人类可读原因
(struct vk-diagnostic (level domain entity reason) #:transparent)

;; 显式收集器：由解析/生成各自创建并**返回**，不是全局参数。
(struct vk-diagnostics (items) #:mutable)

(define (make-diagnostics) (vk-diagnostics '()))

(define (diagnose! diags level domain entity reason)
  (when diags
    (set-vk-diagnostics-items!
     diags (cons (vk-diagnostic level domain entity reason) (vk-diagnostics-items diags))))
  diags)

(define (diagnostics-list diags) (reverse (vk-diagnostics-items diags)))

;; ---------------- 类型事实 ----------------
;; struct 成员：普通字段 / 位域打包单元（解析期算好，生成期不再重算）。
(struct vk-cfield (name ctype) #:transparent)
;; bits：((member-name offset width) ...)，offset 是单元内位偏移
(struct vk-bitgroup (storage base-ctype bits) #:transparent)

;; category : 原始 C 类别 alias | handle | basetype | bitmask | enum | struct | union | funcpointer
;;   （注意：带 alias 的类型 category 仍是原类别；emit 时优先看 alias）
;; alias        : 目标类型名（symbol）或 #f
;;   alias 非 #f 时：只用 alias slot，生成 ctype 别名
;;   handle       : ctype=完整 RHS（(_cpointer/null 'Nm_T)）
;;   basetype     : ctype=RHS（映射后的 ctype）
;;   bitmask/enum : ctype=RHS（_uint32/_uint64/_int32）
;;   struct       : layout=(listof vk-cfield/vk-bitgroup)；sType=可扩展时的 sType 常量名
;;   union        : union-ctypes=(listof ctype)
;;   funcpointer  : func-ret / func-args
(struct vk-type
  (name category alias ctype layout union-ctypes func-ret func-args sType)
  #:transparent)

;; ---------------- 命令绑定事实 ----------------
;; arity : 形参个数；fun : `_fun` 契约形式（define-vk 的第 4 个参数）
(struct vk-func (name level arity fun) #:transparent)

;; ---------------- 模型 ----------------
;; version              : "X.Y.Z"（= 注册表版本，写进 version.rkt）
;; feature/extensions   : 目标参数
;; closure              : feature 依赖闭包
;; requested-extensions : 请求的扩展名；ext-closure：含依赖的闭包
;; feat-types           : feature 直接 require 的类型名（ABI 审计筛选用）
;; wanted-cmds          : 纳入的命令名（含扩展，排序前）
;; wanted-list          : 参与生成的类型名（排序，ABI 审计遍历用）
;; constants            : 有序 (name . valexpr)
;; types                : vk-type，by-value 依赖拓扑序（= types.rkt 顺序）
;; functions            : vk-func，命令原序（= commands.rkt 顺序）
;; commands             : vk-command IR（safe/facts 消费）
;; enums/structs/other-types : types 的类别划分（各领域生成入口）
(struct vk-model
  (version
   feature extensions closure
   requested-extensions ext-closure feat-types
   wanted-cmds wanted-list
   constants types functions commands
   enums structs other-types)
  #:transparent)
