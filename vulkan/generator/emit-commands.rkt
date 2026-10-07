#lang racket/base
;; ============================================================
;; commands.inc 的形式生成 + generated/api.rkt 的数据序列化。
;; ============================================================

(require racket/list
         "../api-facts.rkt"
         "xexpr.rkt"
         "registry.rkt"
         "ctype.rkt"
         "facts-build.rkt")

(provide command-forms command->datum)

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

;; vk-command -> 可写出的 datum（写进 generated/api.rkt）
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
