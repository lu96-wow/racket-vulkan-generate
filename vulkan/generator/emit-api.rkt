#lang racket/base
;; ============================================================
;; generated/facts.rkt 的数据序列化：vk-command 事实 -> #lang racket/base 模块。
;;
;; commands.inc 的形式生成在 emit-commands.rkt；本模块只管运行期事实数据。
;; ============================================================

(require "../api-facts.rkt")

(provide command->datum
         write-facts-module)

;; vk-command -> 可写出的 datum（写进 generated/facts.rkt）
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

(define (write-facts-module commands path)
  (call-with-output-file path #:exists 'replace
    (λ (o)
      (display "#lang racket/base\n" o)
      (display ";; 自动生成（vulkan/generator）：命令/参数事实，供组合层与测试消费。不要手改。\n" o)
      (display "(require vulkan/api-facts)\n" o)
      (display "(provide (all-from-out vulkan/api-facts) vk-command-facts)\n\n" o)
      (display "(define vk-command-facts\n  (list\n" o)
      (for ([c (in-list commands)])
        (display "    " o) (write (command->datum c) o) (newline o))
      (display "))\n" o))))
