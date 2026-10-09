#lang racket/base
;; ============================================================
;; GIPA/GDPA 全量对账（dispatch 层级的 oracle）
;;
;; `command-level` 现在从 registry 事实推导（dispatchable handle + parent 链），
;; 这里用真实 loader 验证：对每条生成命令，按推断层级解析，并检查不变量：
;;   * 硬不变量：GDPA 能解析 ⇒ 该命令必须是 device 级（否则层级偏低）
;;   * instance/global 级不得被 GDPA 解析
;;   * core 命令 + 本机可用扩展的命令：在自身层级必须可解析
;;   * global 命令：libvulkan 符号或 GIPA 至少一条路径可解析
;;
;; 本机不可用的扩展（如某些平台 surface）只报告、不判失败。
;; ============================================================

(require rackunit
         racket/list
         racket/set
         racket/string
         racket/path
         racket/runtime-path
         ffi/unsafe
         vulkan
         vulkan/generated/facts
         vulkan-gen/vk-registry
         vulkan-gen/extension-select)

(define-runtime-path here ".")
(define root (simplify-path (build-path here "..")))
(define reg-path (build-path root "registry" "vk-1.4.363.xml"))

(define (name-array names)
  (define n (length names))
  (define arr (vk-malloc _pointer n))
  (for ([nm names] [i (in-naturals)])
    (ptr-set! arr _pointer i (stable-bytes (string->bytes/utf-8 nm))))
  (values n arr))

;; ---- 命令 -> 提供它的扩展（core 命令不在表里）----
(define reg (load-registry reg-path))
(define selected-exts (extension-closure reg vk-generated-extensions))
(define cmd->ext
  (let ([h (make-hash)])
    (for ([e (in-list selected-exts)])
      (define-values (cmds _tys _ens) (collect-extension-requires reg (list e)))
      (for ([c (in-list cmds)]) (hash-set! h c e)))
    h))

;; ---- 建 instance（启用本机可用的 common 扩展，API 1.4）----
(define (make-instance)
  (define want (list->set vk-generated-extensions))
  (define inst-exts (for/list ([e (vk-instance-extension-properties)] #:when (set-member? want e)) e))
  (define-values (n arr) (name-array inst-exts))
  (define app (make-VkApplicationInfo VK_STRUCTURE_TYPE_APPLICATION_INFO #f #f 0 #f 0 VK_API_VERSION_1_4))
  (define ici (make-VkInstanceCreateInfo VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO #f 0 app 0 #f n arr))
  (define p (vk-malloc _VkInstance))
  (raw:vkCreateInstance ici #f p)
  (values (ptr-ref p _VkInstance) inst-exts))

(define (pick-physical-device inst)
  (define n (vk-malloc _uint32))
  (raw:vkEnumeratePhysicalDevices inst n #f)
  (define cnt (ptr-ref n _uint32))
  (if (zero? cnt)
      #f
      (let ([arr (vk-malloc _VkPhysicalDevice cnt)])
        (raw:vkEnumeratePhysicalDevices inst n arr)
        (ptr-ref arr _VkPhysicalDevice 0))))

(define (make-device pd)
  (define want (list->set vk-generated-extensions))
  (define dev-exts (for/list ([e (vk-device-extension-properties pd)] #:when (set-member? want e)) e))
  (define-values (n arr) (name-array dev-exts))
  (define prio (vk-malloc _float))
  (ptr-set! prio _float 1.0)
  (define qci (make-VkDeviceQueueCreateInfo VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO #f 0 0 1 prio))
  (define dci (make-VkDeviceCreateInfo VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO #f 0 1 qci 0 #f n arr #f))
  (define p (vk-malloc _VkDevice))
  (raw:vkCreateDevice pd dci #f p)
  (values (ptr-ref p _VkDevice) dev-exts))

(define-values (inst inst-exts) (make-instance))
(define pd (pick-physical-device inst))
(cond
  [(not pd) (printf "dispatch-audit: skipped (no physical device)\n")]
  [else
   (define-values (dev dev-exts) (make-device pd))
   (define avail (list->set (append inst-exts dev-exts)))

   ;; 命令是否在本机“应当可解析”：core 或提供它的扩展本机可用
   (define (must-resolve? name)
     (define e (hash-ref cmd->ext name #f))
     (or (not e) (set-member? avail e)))

   (define (gipa-name name) (vkGetInstanceProcAddr inst name))
   (define (gdpa-name name) (vkGetDeviceProcAddr dev name))

   (define violations-level
     (for/list ([c (in-list vk-command-facts)]
                #:when (let ([nm (symbol->string (vk-command-name c))])
                         (and (not (eq? (vk-command-level c) 'device)) (gdpa-name nm))))
       (vk-command-name c)))
   (check-equal? violations-level '()
                 "no instance/global command may resolve via vkGetDeviceProcAddr")

   (define missing
     (filter values
       (for/list ([c (in-list vk-command-facts)])
         (define nm (symbol->string (vk-command-name c)))
         (and (must-resolve? nm)
              (not (case (vk-command-level c)
                     [(device) (gdpa-name nm)]
                     [(instance) (gipa-name nm)]
                     [(global) (or (gipa-name nm) (vk-lib-symbol nm))]
                     [else #f]))
              (list (vk-command-level c) (vk-command-name c))))))
   (check-equal? missing '()
                 "core + locally-available-extension commands must resolve at their inferred level")

   (define unresolved
     (for/list ([c (in-list vk-command-facts)]
                #:when (let ([nm (symbol->string (vk-command-name c))])
                         (not (or (gipa-name nm) (gdpa-name nm) (vk-lib-symbol nm)))))
       (list (vk-command-level c) (vk-command-name c))))

   (printf "dispatch-audit: ~a commands; inst-exts=~a dev-exts=~a\n"
           (length vk-command-facts) (length inst-exts) (length dev-exts))
   (when (pair? unresolved)
     (printf "  unresolved (no GIPA/GDPA/lib symbol; extension not available locally):\n")
     (for ([u (in-list unresolved)]) (printf "    ~a ~a\n" (car u) (cadr u))))
   (printf "dispatch-audit: all checks passed\n")])
