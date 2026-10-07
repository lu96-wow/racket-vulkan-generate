#lang racket/base
;; ============================================================
;; M3.2 分类防回归：classify 对全量命令做纯函数断言
;; ============================================================

(require rackunit
         racket/list
         vulkan/generator/classify
         vulkan/generated/api)

(define (find-cmd name)
  (for/first ([c (in-list vk-command-facts)] #:when (eq? (vk-command-name c) name)) c))

(define (shape-of name)
  (define c (find-cmd name))
  (check-not-false c (format "command exists: ~a" name))
  (vk-plan-shape (classify-command c)))

;; 代表性命令落位
(check-equal? (shape-of 'vkCreateBuffer) 'make-handle)
(check-equal? (shape-of 'vkCreateGraphicsPipelines) 'make-handles)
(check-equal? (shape-of 'vkAllocateCommandBuffers) 'make-handles-info-count)
(check-equal? (shape-of 'vkAllocateDescriptorSets) 'make-handles-info-count)
(check-equal? (shape-of 'vkAllocateMemory) 'make-handle)
(check-equal? (shape-of 'vkDestroyBuffer) 'destroy-handle)
(check-equal? (shape-of 'vkFreeCommandBuffers) 'destroy-handles)
(check-equal? (shape-of 'vkFreeDescriptorSets) 'destroy-handles)
(check-equal? (shape-of 'vkGetPhysicalDeviceProperties) 'out-single)
(check-equal? (shape-of 'vkEnumeratePhysicalDevices) 'out-array)
(check-equal? (shape-of 'vkGetPhysicalDeviceQueueFamilyProperties) 'out-array)
(check-equal? (shape-of 'vkCmdSetViewport) 'in-array)
(check-equal? (shape-of 'vkCmdSetScissor) 'in-array)

;; 应被跳过（复杂/多输入/多输出）
(check-equal? (shape-of 'vkCmdBindPipeline) 'skip)
(check-equal? (shape-of 'vkUpdateDescriptorSets) 'skip)
(check-equal? (shape-of 'vkQueueSubmit) 'skip)      ; VkSubmitInfo 含指针，非 flat
(check-equal? (shape-of 'vkCmdBindDescriptorSets) 'skip)

;; 分类确定（同一命令两次结果一致）
(for ([c (in-list vk-command-facts)])
  (define a (classify-command c))
  (define b (classify-command c))
  (check-equal? (vk-plan-shape a) (vk-plan-shape b)))

;; 每个 non-skip shape 至少有一个真实命令（避免 emitter 成死代码）。
;; in-single 暂无可用的 flat 单结构体输入命令，保留但允许未使用。
(for ([s (in-list shape-symbols)] #:unless (memq s '(skip in-single)))
  (check-true (for/or ([c (in-list vk-command-facts)])
                (eq? (vk-plan-shape (classify-command c)) s))
              (format "shape has at least one command: ~a" s)))

;; 计划的 slot 一致性：out 类必有 out；in 类必有 in
(for ([c (in-list vk-command-facts)])
  (define p (classify-command c))
  (case (vk-plan-shape p)
    [(out-single out-array) (check-not-false (vk-plan-output p))]
    [(in-single in-array) (check-not-false (vk-plan-input p))]
    [else (void)]))

(printf "gen-shapes: all checks passed (~a commands)\n" (length vk-command-facts))
