#lang racket/base
;; ============================================================
;; 运行期 API 事实 IR：命令/参数结构体（vk-param / vk-command）。
;;
;; 位置说明：本模块是**运行期**契约，被生成物 vulkan/generated/facts.rkt 与
;; 生成器 classify/emit 共同依赖，因此放在 vulkan/ 顶层，而不是构建期的
;; vulkan/generator/ 目录里。
;;
;;   vk-param  : name base ctype pointer? const? count? kind output? flat?
;;   vk-command: name level result? dispatch params count-field
;;
;; count-field：仅 vkAllocate* 用（count 在 info 结构体里，例如
;;   VkCommandBufferAllocateInfo.commandBufferCount）；否则 #f。
;; ============================================================

(provide (struct-out vk-param)
         (struct-out vk-command))

;; flat?：struct/union 是否不含指针成员（递归，含嵌套 by-value 结构体）。
;; 仅对 struct/union 有意义；其他类型恒为 #t。用于判断能否安全整体拷贝
;; 输入结构体（嵌套指针/addressing 需用户自行保活）。
(struct vk-param (name base ctype pointer? const? count? kind output? flat?) #:transparent)
(struct vk-command (name level result? dispatch params count-field) #:transparent)
