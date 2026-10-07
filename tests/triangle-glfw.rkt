#lang racket/base
;; ============================================================
;; 完整渲染 + 显示（用独立窗口模块 vulkan/window，GLFW）
;;
;; 窗口逻辑在 vulkan/window.rkt（与 Vulkan 绑定解耦）；
;; 本文件只负责 Vulkan：instance/surface/device/swapchain/pipeline/提交/呈现。
;;
;;   racket test/triangle.rkt           ; 3 帧后退出
;;   racket test/triangle.rkt --loop    ; 持续渲染，关窗或 Esc 退出
;; ============================================================
(require vulkan
         vulkan/window
         ffi/unsafe
         ffi/unsafe/define
         racket/port
         racket/file
         racket/runtime-path)
(file-stream-buffer-mode (current-output-port) 'line)

(define-runtime-path here ".")
(define loop? (and (member "--loop" (vector->list (current-command-line-arguments))) #t))

;; ---------- 窗口（独立模块）----------
(glfw-init!)
(define win (make-glfw-window #:width 640 #:height 480 #:title "racket-vulkan triangle"))
(define-values (WIN-W WIN-H) (glfw-window-framebuffer-size win))
(printf "[ok] window (GLFW, ~a) = ~ax~a\n" (glfw-window-platform) WIN-W WIN-H)

;; ---------- instance（扩展名由 GLFW 提供）----------
(define required-exts (glfw-required-instance-extensions))
(define ext-arr
  (let ()
    (define a (vk-malloc _pointer (length required-exts)))
    (for ([s required-exts] [i (in-naturals)])
      (ptr-set! a _pointer i (stable-bytes (string->bytes/utf-8 s))))
    a))
(define-values (r1 instance)
  (vkCreateInstance
   (λ ()
     (define app (vk-new make-VkApplicationInfo VK_STRUCTURE_TYPE_APPLICATION_INFO
                         #f #f 0 #f 0 VK_API_VERSION_1_1))
     (vk-new make-VkInstanceCreateInfo VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
             #f 0 app 0 #f (length required-exts) ext-arr))
   #f))
(void (vk-use-instance! instance))
(printf "[ok] instance (exts: ~a)\n" required-exts)

;; ---------- surface（GLFW 直接创建，跨平台）----------
(define surface (cast (glfw-create-vk-surface win instance) _pointer _VkSurfaceKHR))
(printf "[ok] surface\n")

;; ---------- physical device + queue family ----------
(define physical-device
  (let ()
    (define cnt (vk-malloc _uint32))
    (raw:vkEnumeratePhysicalDevices instance cnt #f)
    (define n (ptr-ref cnt _uint32))
    (define arr (vk-malloc _VkPhysicalDevice n))
    (raw:vkEnumeratePhysicalDevices instance cnt arr)
    (ptr-ref arr _VkPhysicalDevice)))

(define queue-family-index
  (let* ([cnt (vk-malloc _uint32)])
    (raw:vkGetPhysicalDeviceQueueFamilyProperties physical-device cnt #f)
    (define n (ptr-ref cnt _uint32))
    (define arr (vk-malloc _VkQueueFamilyProperties n))
    (raw:vkGetPhysicalDeviceQueueFamilyProperties physical-device cnt arr)
    (define idx
      (for/fold ([acc #f]) ([i (in-range n)] #:break acc)
        (define p (ptr-ref arr _VkQueueFamilyProperties i))
        (define sup (vk-zero _VkBool32))
        (raw:vkGetPhysicalDeviceSurfaceSupportKHR physical-device i surface sup)
        (if (and (> (VkQueueFamilyProperties-queueCount p) 0)
                 (not (zero? (bitwise-and (VkQueueFamilyProperties-queueFlags p) VK_QUEUE_GRAPHICS_BIT)))
                 (not (zero? (ptr-ref sup _VkBool32))))
            i #f)))
    (unless idx (error 'triangle "no graphics+present queue family"))
    idx))

(define-values (r2 device)
  (vkCreateDevice physical-device
   (λ ()
     (define prio (vk-malloc _float))
     (ptr-set! prio _float 1.0)
     (define qci (vk-new make-VkDeviceQueueCreateInfo
                         VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
                         #f 0 queue-family-index 1 prio))
     (define sw (stable-bytes #"VK_KHR_swapchain"))
     (define arr (vk-malloc _pointer 1))
     (ptr-set! arr _pointer 0 sw)
     (vk-new make-VkDeviceCreateInfo VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
             #f 0 1 qci 0 #f 1 arr #f))
   #f))
(void (vk-use-device! device))
(define queue (let () (define p (vk-malloc _VkQueue))
                (raw:vkGetDeviceQueue device queue-family-index 0 p) (ptr-ref p _VkQueue)))
(printf "[ok] device + queue (family ~a)\n" queue-family-index)

;; ---------- surface info ----------
(define (surface-caps)
  (define c (vk-zero _VkSurfaceCapabilitiesKHR))
  (raw:vkGetPhysicalDeviceSurfaceCapabilitiesKHR physical-device surface c)
  (ptr-ref c _VkSurfaceCapabilitiesKHR))
(define caps (surface-caps))
(define surface-format
  (let ()
    (define c (vk-malloc _uint32))
    (raw:vkGetPhysicalDeviceSurfaceFormatsKHR physical-device surface c #f)
    (define n (ptr-ref c _uint32))
    (define a (vk-malloc _VkSurfaceFormatKHR n))
    (raw:vkGetPhysicalDeviceSurfaceFormatsKHR physical-device surface c a)
    (VkSurfaceFormatKHR-format (ptr-ref a _VkSurfaceFormatKHR 0))))
(define surface-color-space
  (let ()
    (define c (vk-malloc _uint32))
    (raw:vkGetPhysicalDeviceSurfaceFormatsKHR physical-device surface c #f)
    (define n (ptr-ref c _uint32))
    (define a (vk-malloc _VkSurfaceFormatKHR n))
    (raw:vkGetPhysicalDeviceSurfaceFormatsKHR physical-device surface c a)
    (VkSurfaceFormatKHR-colorSpace (ptr-ref a _VkSurfaceFormatKHR 0))))
(define present-mode
  (let ()
    (define c (vk-malloc _uint32))
    (raw:vkGetPhysicalDeviceSurfacePresentModesKHR physical-device surface c #f)
    (define n (ptr-ref c _uint32))
    (define a (vk-malloc _int32 n))
    (raw:vkGetPhysicalDeviceSurfacePresentModesKHR physical-device surface c a)
    (ptr-ref a _int32 0)))
(define composite-alpha
  (let ([m (VkSurfaceCapabilitiesKHR-supportedCompositeAlpha caps)])
    (bitwise-and m (- m))))

;; ---------- swapchain（可重建）----------
(struct sc-state (swapchain extent image-views framebuffers) #:transparent)
(define current-sc #f)

(define (choose-extent)
  (define cur (VkSurfaceCapabilitiesKHR-currentExtent (surface-caps)))
  (if (= (VkExtent2D-width cur) #xFFFFFFFF)
      (let-values ([(w h) (glfw-window-framebuffer-size win)])
        (vk-new make-VkExtent2D (max 1 w) (max 1 h)))
      cur))

(define (create-swapchain)
  (define caps* (surface-caps))
  (define extent (choose-extent))
  (define-values (r3 swapchain)
    (vkCreateSwapchainKHR device
     (λ ()
       (vk-new make-VkSwapchainCreateInfoKHR
               VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
               #f 0 surface
               (max 2 (VkSurfaceCapabilitiesKHR-minImageCount caps*))
               surface-format surface-color-space
               extent 1 VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
               VK_SHARING_MODE_EXCLUSIVE 0 #f
               (VkSurfaceCapabilitiesKHR-currentTransform caps*)
               composite-alpha present-mode VK_TRUE #f))
     #f))
  (define count-p (vk-malloc _uint32))
  (raw:vkGetSwapchainImagesKHR device swapchain count-p #f)
  (define n (ptr-ref count-p _uint32))
  (define images (vk-malloc _VkImage n))
  (raw:vkGetSwapchainImagesKHR device swapchain count-p images)
  (define image-views
    (for/vector ([i (in-range n)])
      (let-values ([(r v) (vkCreateImageView device
       (λ ()
         (vk-new make-VkImageViewCreateInfo
                 VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
                 #f 0 (ptr-ref images _VkImage i) VK_IMAGE_VIEW_TYPE_2D surface-format
                 (vk-new make-VkComponentMapping
                         VK_COMPONENT_SWIZZLE_IDENTITY VK_COMPONENT_SWIZZLE_IDENTITY
                         VK_COMPONENT_SWIZZLE_IDENTITY VK_COMPONENT_SWIZZLE_IDENTITY)
                 (vk-new make-VkImageSubresourceRange VK_IMAGE_ASPECT_COLOR_BIT 0 1 0 1)))
       #f)])
        v)))
  (define framebuffers
    (for/vector ([iv image-views])
      (let-values ([(r v) (vkCreateFramebuffer device
       (λ ()
         (define att (vk-malloc _VkImageView 1))
         (ptr-set! att _VkImageView 0 iv)
         (vk-new make-VkFramebufferCreateInfo VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
                 #f 0 render-pass 1 att
                 (VkExtent2D-width extent) (VkExtent2D-height extent) 1))
       #f)])
        v)))
  (sc-state swapchain extent image-views framebuffers))

(define (destroy-swapchain!)
  (when current-sc
    (for ([fb (sc-state-framebuffers current-sc)]) (raw:vkDestroyFramebuffer device fb #f))
    (for ([iv (sc-state-image-views current-sc)]) (raw:vkDestroyImageView device iv #f))
    (raw:vkDestroySwapchainKHR device (sc-state-swapchain current-sc) #f)
    (set! current-sc #f)))

;; ---------- render pass ----------
(define render-pass (void))   ; placeholder, set below (create-swapchain uses it)
(set! render-pass
      (let-values ([(r v)
                    (vkCreateRenderPass device
       (λ ()
         (define color-ref (vk-new make-VkAttachmentReference 0 VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL))
         (define subpass (vk-new make-VkSubpassDescription
                                 0 VK_PIPELINE_BIND_POINT_GRAPHICS 0 #f 1 color-ref #f #f 0 #f))
         (define dep (vk-new make-VkSubpassDependency
                             VK_SUBPASS_EXTERNAL 0
                             VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
                             VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
                             0 VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT 0))
         (define att (vk-new make-VkAttachmentDescription
                             0 surface-format VK_SAMPLE_COUNT_1_BIT
                             VK_ATTACHMENT_LOAD_OP_CLEAR VK_ATTACHMENT_STORE_OP_STORE
                             VK_ATTACHMENT_LOAD_OP_DONT_CARE VK_ATTACHMENT_STORE_OP_DONT_CARE
                             VK_IMAGE_LAYOUT_UNDEFINED VK_IMAGE_LAYOUT_PRESENT_SRC_KHR))
         (vk-new make-VkRenderPassCreateInfo VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
                 #f 0 1 att 1 subpass 1 dep))
       #f)])
        v))

(set! current-sc (create-swapchain))
(printf "[ok] swapchain ~ax~a, ~a image views\n"
        (VkExtent2D-width (sc-state-extent current-sc))
        (VkExtent2D-height (sc-state-extent current-sc))
        (vector-length (sc-state-image-views current-sc)))

;; ---------- shaders + pipeline（dynamic viewport/scissor）----------
(define (spv name) (stable-bytes (file->bytes (build-path here "shaders" name))))
(define-values (r4 vert-module)
  (vkCreateShaderModule device
   (λ () (define code (spv "triangle.vert.spv"))
     (vk-new make-VkShaderModuleCreateInfo VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
             #f 0 (file-size (build-path here "shaders" "triangle.vert.spv")) code)) #f))
(define-values (r5 frag-module)
  (vkCreateShaderModule device
   (λ () (define code (spv "triangle.frag.spv"))
     (vk-new make-VkShaderModuleCreateInfo VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
             #f 0 (file-size (build-path here "shaders" "triangle.frag.spv")) code)) #f))
(define-values (r6 pipeline-layout)
  (vkCreatePipelineLayout device
   (λ () (vk-new make-VkPipelineLayoutCreateInfo
                 VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO #f 0 0 #f 0 #f)) #f))

(define pipeline
  (let-values ([(r ps)
                (vkCreateGraphicsPipelines device
    (λ ()
      (define stages (vk-struct-array _VkPipelineShaderStageCreateInfo
                                     (list
                                      (vk-new make-VkPipelineShaderStageCreateInfo
                                              VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
                                              #f 0 VK_SHADER_STAGE_VERTEX_BIT vert-module
                                              (stable-bytes #"main") #f)
                                      (vk-new make-VkPipelineShaderStageCreateInfo
                                              VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
                                              #f 0 VK_SHADER_STAGE_FRAGMENT_BIT frag-module
                                              (stable-bytes #"main") #f))))
      (define vertex-input (vk-new make-VkPipelineVertexInputStateCreateInfo
                                   VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
                                   #f 0 0 #f 0 #f))
      (define ia (vk-new make-VkPipelineInputAssemblyStateCreateInfo
                         VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
                         #f 0 VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST VK_FALSE))
      ;; viewport/scissor 动态
      (define vp (vk-new make-VkPipelineViewportStateCreateInfo
                         VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
                         #f 0 1 #f 1 #f))
      (define dyn (vk-new make-VkPipelineDynamicStateCreateInfo
                          VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
                          #f 0 2 (vk-struct-array _VkDynamicState
                                                  (list VK_DYNAMIC_STATE_VIEWPORT
                                                        VK_DYNAMIC_STATE_SCISSOR))))
      (define rast (vk-new make-VkPipelineRasterizationStateCreateInfo
                           VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
                           #f 0 VK_FALSE VK_FALSE VK_POLYGON_MODE_FILL
                           VK_CULL_MODE_NONE VK_FRONT_FACE_COUNTER_CLOCKWISE
                           VK_FALSE 0.0 0.0 0.0 1.0))
      (define ms (vk-new make-VkPipelineMultisampleStateCreateInfo
                         VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
                         #f 0 VK_SAMPLE_COUNT_1_BIT VK_FALSE 0.0 #f VK_FALSE VK_FALSE))
      (define cba (vk-new make-VkPipelineColorBlendAttachmentState
                          VK_FALSE VK_BLEND_FACTOR_ZERO VK_BLEND_FACTOR_ZERO VK_BLEND_OP_ADD
                          VK_BLEND_FACTOR_ZERO VK_BLEND_FACTOR_ZERO VK_BLEND_OP_ADD
                          (bitwise-ior VK_COLOR_COMPONENT_R_BIT VK_COLOR_COMPONENT_G_BIT
                                       VK_COLOR_COMPONENT_B_BIT VK_COLOR_COMPONENT_A_BIT)))
      (define cb (ptr-ref (vk-zero _VkPipelineColorBlendStateCreateInfo)
                          _VkPipelineColorBlendStateCreateInfo))
      (set-VkPipelineColorBlendStateCreateInfo-sType! cb VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO)
      (set-VkPipelineColorBlendStateCreateInfo-logicOpEnable! cb VK_FALSE)
      (set-VkPipelineColorBlendStateCreateInfo-attachmentCount! cb 1)
      (set-VkPipelineColorBlendStateCreateInfo-pAttachments! cb cba)
      (vector (vk-new make-VkGraphicsPipelineCreateInfo
                      VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
                      #f 0 2 stages vertex-input ia #f vp rast ms #f cb dyn
                      pipeline-layout render-pass 0 #f 0)))
    #f #f)])
   (vector-ref ps 0)))
(printf "[ok] graphics pipeline\n")

;; ---------- command pool + buffers ----------
(define-values (r7 command-pool)
  (vkCreateCommandPool device
   (λ () (vk-new make-VkCommandPoolCreateInfo VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
                                              #f VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
                                              queue-family-index)) #f))
(define command-buffer
  (let-values ([(r cbs) (vkAllocateCommandBuffers device
                          (λ () (vk-new make-VkCommandBufferAllocateInfo
                                        VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
                                        #f command-pool VK_COMMAND_BUFFER_LEVEL_PRIMARY 1)))])
    (vector-ref cbs 0)))

;; ---------- sync ----------
(define (make-semaphore)
  (let-values ([(r s) (vkCreateSemaphore device
                      (λ () (vk-new make-VkSemaphoreCreateInfo VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO #f 0)) #f)])
    s))
(define image-available (make-semaphore))
(define render-finished-sems
  (for/vector ([i (in-range (vector-length (sc-state-image-views current-sc)))]) (make-semaphore)))
(define-values (r8 in-flight)
  (vkCreateFence device
   (λ () (vk-new make-VkFenceCreateInfo VK_STRUCTURE_TYPE_FENCE_CREATE_INFO #f VK_FENCE_CREATE_SIGNALED_BIT)) #f))

;; ---------- record ----------
(define clear-color (list 0.05 0.05 0.10 1.0))
(define (record! image-index)
  (raw:vkResetCommandBuffer command-buffer 0)
  (raw:vkBeginCommandBuffer command-buffer
    (vk-new make-VkCommandBufferBeginInfo VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
            #f VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT #f))
  (define clear (vk-zero _VkClearValue))
  (for ([v clear-color] [i (in-naturals)])
    (ptr-set! clear _float i (exact->inexact v)))
  (define extent (sc-state-extent current-sc))
  (raw:vkCmdBeginRenderPass command-buffer
    (vk-new make-VkRenderPassBeginInfo VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
            #f render-pass (vector-ref (sc-state-framebuffers current-sc) image-index)
            (vk-new make-VkRect2D (vk-new make-VkOffset2D 0 0) extent)
            1 clear)
    VK_SUBPASS_CONTENTS_INLINE)
  (raw:vkCmdBindPipeline command-buffer VK_PIPELINE_BIND_POINT_GRAPHICS pipeline)
  (raw:vkCmdSetViewport command-buffer 0 1
    (vk-new make-VkViewport 0.0 0.0
            (exact->inexact (VkExtent2D-width extent))
            (exact->inexact (VkExtent2D-height extent)) 0.0 1.0))
  (raw:vkCmdSetScissor command-buffer 0 1 (vk-new make-VkRect2D (vk-new make-VkOffset2D 0 0) extent))
  (raw:vkCmdDraw command-buffer 3 1 0 0)
  (raw:vkCmdEndRenderPass command-buffer)
  (raw:vkEndCommandBuffer command-buffer))

;; ---------- helpers ----------
(define (fence-ptr) (let ([p (vk-malloc _VkFence)]) (ptr-set! p _VkFence in-flight) p))
(define (sem-ptr s) (let ([p (vk-malloc _VkSemaphore 1)]) (ptr-set! p _VkSemaphore 0 s) p))
(define (u32-ptr v) (let ([p (vk-malloc _uint32 1)]) (ptr-set! p _uint32 0 v) p))
(define (cmd-ptr) (let ([p (vk-malloc _VkCommandBuffer 1)]) (ptr-set! p _VkCommandBuffer 0 command-buffer) p))

(define (recreate-swapchain!)
  (raw:vkDeviceWaitIdle device)
  (destroy-swapchain!)
  (set! current-sc (create-swapchain)))

;; ---------- main loop ----------
(define last-extent (list (VkExtent2D-width (sc-state-extent current-sc))
                          (VkExtent2D-height (sc-state-extent current-sc))))
(define max-frames (if loop? 1000000000 3))
(let loop ([frame 0])
  (glfw-window-poll! win)
  (when (and (< frame max-frames) (not (glfw-window-should-close? win)))
    (define-values (w h) (glfw-window-framebuffer-size win))
    (cond
      [(or (zero? w) (zero? h))
       ;; 最小化：等一会儿
       (sleep 0.05)
       (loop frame)]
      [else
       (unless (and (= w (car last-extent)) (= h (cadr last-extent)))
         (set! last-extent (list w h))
         (recreate-swapchain!)
         (for ([s render-finished-sems]) (raw:vkDestroySemaphore device s #f))
         (set! render-finished-sems
               (for/vector ([i (in-range (vector-length (sc-state-image-views current-sc)))])
                 (make-semaphore))))
       (raw:vkWaitForFences device 1 (fence-ptr) VK_TRUE (* 10 1000000000))
       (raw:vkResetFences device 1 (fence-ptr))
       (define image-index-p (vk-malloc _uint32))
       (raw:vkAcquireNextImageKHR device (sc-state-swapchain current-sc) (* 10 1000000000)
                              image-available #f image-index-p)
       (define image-index (ptr-ref image-index-p _uint32))
       (record! image-index)
       (define rf (vector-ref render-finished-sems image-index))
       (define wait-stage (vk-malloc _int32 1))
       (ptr-set! wait-stage _int32 0 VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT)
       (raw:vkQueueSubmit queue 1
         (vk-new make-VkSubmitInfo VK_STRUCTURE_TYPE_SUBMIT_INFO
                 #f 1 (sem-ptr image-available) wait-stage 1 (cmd-ptr) 1 (sem-ptr rf))
         in-flight)
       (define swapchains (vk-malloc _VkSwapchainKHR 1))
       (ptr-set! swapchains _VkSwapchainKHR 0 (sc-state-swapchain current-sc))
       (raw:vkQueuePresentKHR queue
         (vk-new make-VkPresentInfoKHR VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
                 #f 1 (sem-ptr rf) 1 swapchains (u32-ptr image-index) #f))
       (when (or (not loop?) (< frame 5))
         (printf "[ok] frame ~a: image ~a presented\n" frame image-index))
       (if loop?
           (begin (sleep 0.016) (loop (add1 frame)))
           (loop (add1 frame)))])))

(raw:vkQueueWaitIdle queue)
(raw:vkDeviceWaitIdle device)
(printf "[ok] presented ~a frames\n" (if loop? "many" max-frames))

;; ---------- cleanup ----------
(raw:vkDestroyFence device in-flight #f)
(for ([s render-finished-sems]) (raw:vkDestroySemaphore device s #f))
(raw:vkDestroySemaphore device image-available #f)
(raw:vkDestroyCommandPool device command-pool #f)
(raw:vkDestroyPipeline device pipeline #f)
(raw:vkDestroyPipelineLayout device pipeline-layout #f)
(raw:vkDestroyShaderModule device frag-module #f)
(raw:vkDestroyShaderModule device vert-module #f)
(raw:vkDestroyRenderPass device render-pass #f)
(destroy-swapchain!)
(raw:vkDestroyDevice device #f)
(raw:vkDestroySurfaceKHR instance surface #f)
(raw:vkDestroyInstance instance #f)
(glfw-window-destroy! win)
(glfw-terminate!)
(printf "[ok] done\n")
