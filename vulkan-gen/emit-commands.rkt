#lang racket/base
;; ============================================================
;; commands.inc 的形式生成。
;;
;; 运行期事实数据（generated/facts.rkt）的序列化在 emit-api.rkt。
;; ============================================================

(require racket/list
         "xexpr.rkt"
         "vk-registry.rkt"
         "ctype.rkt"
         "facts-build.rkt")

(provide command-forms)

;; alias 命令沿用目标命令的签名（proto/params/level）；基础层只做绑定：
;; VkResult 命令直接返回结果值，错误策略在 safe 层。
(define (command-form reg c)
  (define nm (command-name c))
  (define eff (resolve-command reg c))
  (define proto (find-first-by-tag 'proto eff))
  (define ret-base (base-c-type-name (member-type-text proto)))
  (define params (params-of eff))
  (define types (map (λ (p) (param-ctype reg p)) params))
  (define fun
    (if (equal? ret-base "VkResult")
        `(_fun ,@types -> _VkResult)
        `(_fun ,@types -> ,(ctype-of-type-name reg ret-base))))
  `(define-vk ,(string->symbol nm) ,(command-level reg eff) ,(length params) ,fun))

(define (command-forms reg wanted-cmds)
  (filter values
          (for/list ([nm wanted-cmds]
                     #:when (and nm (not (member nm skip-commands))))
            (define c (hash-ref (registry-commands-hash reg) (string->symbol nm) #f))
            (and c (command-form reg c)))))
