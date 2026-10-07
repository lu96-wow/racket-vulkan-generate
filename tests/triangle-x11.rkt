#lang racket/base
;; ============================================================
;; 完整渲染 + 显示：X 窗口 + swapchain + graphics pipeline + 三角形
;; 证明当前生成的 API 足以渲染和显示。
;; ============================================================
(require vulkan
         ffi/unsafe
         ffi/unsafe/define
         racket/port
         racket/file
         racket/runtime-path)
(file-stream-buffer-mode (current-output-port) 'line)

(define-runtime-path here ".")

;; ---------- X11 ----------
(define-ffi-definer define-x11 (ffi-lib "libX11" '("6" "")))
(define-x11 XOpenDisplay (_fun _pointer -> _pointer))
(define-x11 XDefaultScreen (_fun _pointer -> _int))
(define-x11 XRootWindow (_fun _pointer _int -> _ulong))
(define-x11 XCreateSimpleWindow (_fun _pointer _ulong _int _int _uint _uint _uint _ulong _ulong -> _ulong))
(define-x11 XMapWindow (_fun _pointer _ulong -> _int))
(define-x11 XStoreName (_fun _pointer _ulong _string -> _int))
(define-x11 XFlush (_fun _pointer -> _int))
(define-x11 XDestroyWindow (_fun _pointer _ulong -> _int))
(define-x11 XCloseDisplay (_fun _pointer -> _int))
(define-x11 XInternAtom (_fun _pointer _string _int -> _ulong))
(define-x11 XSetWMProtocols (_fun _pointer _ulong _pointer _int -> _int))
(define-x11 XPending (_fun _pointer -> _int))
(define-x11 XNextEvent (_fun _pointer _pointer -> _int))

(define WIDTH 640)
(define HEIGHT 480)
(define FRAMES 3)
(define loop? (and (member "--loop" (vector->list (current-command-line-arguments))) #t))

(define dpy (XOpenDisplay #f))
(unless dpy (error 'triangle "cannot open X display"))
(define screen (XDefaultScreen dpy))
(define win (XCreateSimpleWindow dpy (XRootWindow dpy screen) 0 0 WIDTH HEIGHT 0 0 #x000000))
(void (XStoreName dpy win "racket-vulkan triangle"))
(void (XMapWindow dpy win))
(define wm-delete (XInternAtom dpy "WM_DELETE_WINDOW" 0))
(define protocol-atom (malloc 'atomic-interior _ulong 1))
(ptr-set! protocol-atom _ulong 0 wm-delete)
(void (XSetWMProtocols dpy win protocol-atom 1))
(void (XFlush dpy))
(define event-buf (malloc 'atomic-interior _uint8 192))
(define (window-closed?)
  (let poll ()
    (if (> (XPending dpy) 0)
        (let* ([_ (void (XNextEvent dpy event-buf))]
               [type (ptr-ref event-buf _int 0)])
          (cond
            [(= type 33)                       ; ClientMessage
             ;; message_type = WM_PROTOCOLS, data.l[0] = 具体协议 atom
             (if (= (ptr-ref event-buf _ulong 7) wm-delete) #t (poll))]
            [(= type 2)                        ; KeyPress
             (if (= (ptr-ref event-buf _uint8 84) 9) #t (poll))]  ; Escape
            [(= type 17) #t]                   ; DestroyNotify
            [else (poll)]))
        #f)))
(printf "[ok] X window = ~a (~ax~a)\n" win WIDTH HEIGHT)

;; ---------- instance ----------
(define x11-exts (list #"VK_KHR_surface" #"VK_KHR_xlib_surface"))
(define ext-arr
  (let ()
    (define a (vk-malloc _pointer (length x11-exts)))
    (for ([b x11-exts] [i (in-naturals)]) (ptr-set! a _pointer i (stable-bytes b)))
    a))
(define-values (r1 instance)
  (vkCreateInstance
   (λ ()
     (define app (vk-new make-VkApplicationInfo VK_STRUCTURE_TYPE_APPLICATION_INFO
                         #f #f 0 #f 0 VK_API_VERSION_1_1))
     (vk-new make-VkInstanceCreateInfo VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
             #f 0 app 0 #f (length x11-exts) ext-arr))
   #f))
(register-vk-instance! instance)
(printf "[ok] instance\n")

(define-values (r2 surface)
  (vkCreateXlibSurfaceKHR instance
   (λ () (vk-new make-VkXlibSurfaceCreateInfoKHR
                 VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR #f 0 dpy win))
   #f))
(printf "[ok] surface\n")

;; ---------- physical device + queue family (graphics + present) ----------
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
(printf "[ok] queue family = ~a\n" queue-family-index)

(define-values (r3 device)
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
(register-vk-device! device)
(printf "[ok] device\n")

(define queue
  (let ()
    (define p (vk-malloc _VkQueue))
    (raw:vkGetDeviceQueue device queue-family-index 0 p)
    (ptr-ref p _VkQueue)))

;; ---------- swapchain ----------
(define caps-p (vk-zero _VkSurfaceCapabilitiesKHR))
(raw:vkGetPhysicalDeviceSurfaceCapabilitiesKHR physical-device surface caps-p)
(define caps (ptr-ref caps-p _VkSurfaceCapabilitiesKHR))

(define fmt-count-p (vk-malloc _uint32))
(raw:vkGetPhysicalDeviceSurfaceFormatsKHR physical-device surface fmt-count-p #f)
(define nfmt (ptr-ref fmt-count-p _uint32))
(define fmt-arr (vk-malloc _VkSurfaceFormatKHR nfmt))
(raw:vkGetPhysicalDeviceSurfaceFormatsKHR physical-device surface fmt-count-p fmt-arr)
(define fmt (ptr-ref fmt-arr _VkSurfaceFormatKHR 0))
(define surface-format (VkSurfaceFormatKHR-format fmt))
(define surface-color-space (VkSurfaceFormatKHR-colorSpace fmt))

(define pm-count-p (vk-malloc _uint32))
(raw:vkGetPhysicalDeviceSurfacePresentModesKHR physical-device surface pm-count-p #f)
(define npm (ptr-ref pm-count-p _uint32))
(define pm-arr (vk-malloc _int32 npm))
(raw:vkGetPhysicalDeviceSurfacePresentModesKHR physical-device surface pm-count-p pm-arr)

(define composite-mask (VkSurfaceCapabilitiesKHR-supportedCompositeAlpha caps))
(define composite-alpha (bitwise-and composite-mask (- composite-mask)))
(define extent (VkSurfaceCapabilitiesKHR-currentExtent caps))
(define usage-flags (VkSurfaceCapabilitiesKHR-supportedUsageFlags caps))
(define want-transfer-src? (not (zero? (bitwise-and usage-flags VK_IMAGE_USAGE_TRANSFER_SRC_BIT))))
(define image-usage (bitwise-ior VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
                                 (if want-transfer-src? VK_IMAGE_USAGE_TRANSFER_SRC_BIT 0)))

(define-values (r4 swapchain)
  (vkCreateSwapchainKHR device
   (λ ()
     (vk-new make-VkSwapchainCreateInfoKHR
             VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
             #f 0 surface
             (max 2 (VkSurfaceCapabilitiesKHR-minImageCount caps))
             surface-format surface-color-space
             extent 1 image-usage
             VK_SHARING_MODE_EXCLUSIVE 0 #f
             (VkSurfaceCapabilitiesKHR-currentTransform caps)
             composite-alpha
             (ptr-ref pm-arr _int32 0) VK_TRUE #f))
   #f))
(printf "[ok] swapchain ~ax~a format=~a transfer-src=~a\n"
        (VkExtent2D-width extent) (VkExtent2D-height extent) surface-format want-transfer-src?)

(define image-count-p (vk-malloc _uint32))
(raw:vkGetSwapchainImagesKHR device swapchain image-count-p #f)
(define nimages (ptr-ref image-count-p _uint32))
(define image-arr (vk-malloc _VkImage nimages))
(raw:vkGetSwapchainImagesKHR device swapchain image-count-p image-arr)
(printf "[ok] swapchain images = ~a\n" nimages)

;; image views
(define image-views
  (for/vector ([i (in-range nimages)])
    (define img (ptr-ref image-arr _VkImage i))
    (let-values ([(r v)
                  (vkCreateImageView device
     (λ ()
       (define range (vk-new make-VkImageSubresourceRange
                             VK_IMAGE_ASPECT_COLOR_BIT 0 1 0 1))
       (define comps (vk-new make-VkComponentMapping
                             VK_COMPONENT_SWIZZLE_IDENTITY VK_COMPONENT_SWIZZLE_IDENTITY
                             VK_COMPONENT_SWIZZLE_IDENTITY VK_COMPONENT_SWIZZLE_IDENTITY))
       (vk-new make-VkImageViewCreateInfo VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
               #f 0 img VK_IMAGE_VIEW_TYPE_2D surface-format comps range))
     #f)])
      v)))
(printf "[ok] ~a image views\n" (vector-length image-views))

;; ---------- render pass ----------
(define-values (r5 render-pass)
  (vkCreateRenderPass device
   (λ ()
     (define color-ref (vk-new make-VkAttachmentReference 0 VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL))
     (define subpass (vk-new make-VkSubpassDescription
                             0 VK_PIPELINE_BIND_POINT_GRAPHICS
                             0 #f 1 color-ref #f #f 0 #f))
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
   #f))
(printf "[ok] render pass\n")

;; ---------- shaders ----------
(define (spv name) (stable-bytes (file->bytes (build-path here "shaders" name))))
(define-values (r6 vert-module)
  (vkCreateShaderModule device
   (λ ()
     (define code (spv "triangle.vert.spv"))
     (vk-new make-VkShaderModuleCreateInfo VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
             #f 0 (file-size (build-path here "shaders" "triangle.vert.spv")) code))
   #f))
(define-values (r7 frag-module)
  (vkCreateShaderModule device
   (λ ()
     (define code (spv "triangle.frag.spv"))
     (vk-new make-VkShaderModuleCreateInfo VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
             #f 0 (file-size (build-path here "shaders" "triangle.frag.spv")) code))
   #f))

(define-values (r8 pipeline-layout)
  (vkCreatePipelineLayout device
   (λ () (vk-new make-VkPipelineLayoutCreateInfo
                 VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO #f 0 0 #f 0 #f))
   #f))
(printf "[ok] shader modules + pipeline layout\n")

;; ---------- graphics pipeline ----------
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
      (define viewport (vk-new make-VkViewport 0.0 0.0
                               (exact->inexact (VkExtent2D-width extent))
                               (exact->inexact (VkExtent2D-height extent))
                               0.0 1.0))
      (define scissor (vk-new make-VkRect2D
                              (vk-new make-VkOffset2D 0 0) extent))
      (define vp (vk-new make-VkPipelineViewportStateCreateInfo
                         VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
                         #f 0 1 viewport 1 scissor))
      (define rast (vk-new make-VkPipelineRasterizationStateCreateInfo
                           VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
                           #f 0 VK_FALSE VK_FALSE VK_POLYGON_MODE_FILL
                           VK_CULL_MODE_NONE VK_FRONT_FACE_COUNTER_CLOCKWISE
                           VK_FALSE 0.0 0.0 0.0 1.0))
      (define ms (vk-new make-VkPipelineMultisampleStateCreateInfo
                         VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
                         #f 0 VK_SAMPLE_COUNT_1_BIT VK_FALSE 0.0 #f VK_FALSE VK_FALSE))
      (define cba (vk-new make-VkPipelineColorBlendAttachmentState
                          VK_FALSE
                          VK_BLEND_FACTOR_ZERO VK_BLEND_FACTOR_ZERO VK_BLEND_OP_ADD
                          VK_BLEND_FACTOR_ZERO VK_BLEND_FACTOR_ZERO VK_BLEND_OP_ADD
                          (bitwise-ior VK_COLOR_COMPONENT_R_BIT VK_COLOR_COMPONENT_G_BIT
                                       VK_COLOR_COMPONENT_B_BIT VK_COLOR_COMPONENT_A_BIT)))
      ;; blendConstants[4] 是定长数组，构造器只收一个值 -> 用 vk-zero + setter
      (define cb (ptr-ref (vk-zero _VkPipelineColorBlendStateCreateInfo)
                          _VkPipelineColorBlendStateCreateInfo))
      (set-VkPipelineColorBlendStateCreateInfo-sType! cb VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO)
      (set-VkPipelineColorBlendStateCreateInfo-logicOpEnable! cb VK_FALSE)
      (set-VkPipelineColorBlendStateCreateInfo-logicOp! cb VK_LOGIC_OP_COPY)
      (set-VkPipelineColorBlendStateCreateInfo-attachmentCount! cb 1)
      (set-VkPipelineColorBlendStateCreateInfo-pAttachments! cb cba)
      (vector (vk-new make-VkGraphicsPipelineCreateInfo
                      VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
                      #f 0 2 stages vertex-input ia #f vp rast ms #f cb #f
                      pipeline-layout render-pass 0 #f 0)))
    #f #f)])
   (vector-ref ps 0)))
(printf "[ok] graphics pipeline\n")

;; ---------- framebuffers ----------
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
(printf "[ok] ~a framebuffers\n" (vector-length framebuffers))

;; ---------- command pool + buffer ----------
(define-values (r9 command-pool)
  (vkCreateCommandPool device
   (λ () (vk-new make-VkCommandPoolCreateInfo VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
                                              #f VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
                                              queue-family-index))
   #f))
(define command-buffer
  (let-values ([(r cbs)
                (vkAllocateCommandBuffers device
                 (λ () (vk-new make-VkCommandBufferAllocateInfo
                               VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
                               #f command-pool VK_COMMAND_BUFFER_LEVEL_PRIMARY 1)))])
    (vector-ref cbs 0)))

;; ---------- sync ----------
(define (make-semaphore)
  (let-values ([(r s)
                (vkCreateSemaphore device
                 (λ () (vk-new make-VkSemaphoreCreateInfo VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO #f 0))
                 #f)])
    s))
(define image-available (make-semaphore))
(define render-finished-sems (for/vector ([i (in-range nimages)]) (make-semaphore)))
(define-values (r10 in-flight)
  (vkCreateFence device
   (λ () (vk-new make-VkFenceCreateInfo VK_STRUCTURE_TYPE_FENCE_CREATE_INFO #f VK_FENCE_CREATE_SIGNALED_BIT))
   #f))

;; ---------- readback buffer (frame 0) ----------
(define readback
  (and want-transfer-src?
       (let ()
         (define size (* 4 (VkExtent2D-width extent) (VkExtent2D-height extent)))
         (define-values (r11 buf)
           (vkCreateBuffer device
            (λ () (vk-new make-VkBufferCreateInfo VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
                                                  #f 0 size VK_BUFFER_USAGE_TRANSFER_DST_BIT
                                                  VK_SHARING_MODE_EXCLUSIVE 0 #f))
            #f))
         (define req-p (vk-zero _VkMemoryRequirements))
         (raw:vkGetBufferMemoryRequirements device buf req-p)
         (define req (ptr-ref req-p _VkMemoryRequirements))
         (define (mem-type bits props)
           (define pdmp (vk-zero _VkPhysicalDeviceMemoryProperties))
           (raw:vkGetPhysicalDeviceMemoryProperties physical-device pdmp)
           (define mp (ptr-ref pdmp _VkPhysicalDeviceMemoryProperties))
           (or (for/fold ([acc #f])
                         ([i (in-range (VkPhysicalDeviceMemoryProperties-memoryTypeCount mp))] #:break acc)
                 (define mt (array-ref (VkPhysicalDeviceMemoryProperties-memoryTypes mp) i))
                 (if (and (not (zero? (bitwise-and bits (arithmetic-shift 1 i))))
                          (= (bitwise-and (VkMemoryType-propertyFlags mt) props) props))
                     i #f))
               (error 'triangle "no memory type")))
         (define-values (r12 mem)
           (vkAllocateMemory device
            (λ () (vk-new make-VkMemoryAllocateInfo VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
                                                    #f (VkMemoryRequirements-size req)
                                                    (mem-type (VkMemoryRequirements-memoryTypeBits req)
                                                              (bitwise-ior VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                                                                           VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))))
            #f))
         (raw:vkBindBufferMemory device buf mem 0)
         (vector buf mem size))))

;; ---------- render loop ----------
(define clear-color (list 0.05 0.05 0.10 1.0))

(define (record! image-index cb)
  (raw:vkResetCommandBuffer cb 0)
  (define begin-info (vk-new make-VkCommandBufferBeginInfo
                              VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
                              #f VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT #f))
  (raw:vkBeginCommandBuffer cb begin-info)
  (define clear (vk-zero _VkClearValue))     ; union: 前 16 字节即 float[4] clear color
  (for ([v clear-color] [i (in-naturals)])
    (ptr-set! clear _float i (exact->inexact v)))
  (define rp-begin (vk-new make-VkRenderPassBeginInfo
                           VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
                           #f render-pass (vector-ref framebuffers image-index)
                           (vk-new make-VkRect2D (vk-new make-VkOffset2D 0 0) extent)
                           1 clear))
  (raw:vkCmdBeginRenderPass cb rp-begin VK_SUBPASS_CONTENTS_INLINE)
  (raw:vkCmdBindPipeline cb VK_PIPELINE_BIND_POINT_GRAPHICS pipeline)
  (raw:vkCmdDraw cb 3 1 0 0)
  (raw:vkCmdEndRenderPass cb)
  (when (and readback (= image-index 0))
    ;; PRESENT_SRC -> TRANSFER_SRC -> copy -> PRESENT_SRC
    (define (real-barrier old new)
      (define b (vk-new make-VkImageMemoryBarrier
                        VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
                        #f
                        (if (= old VK_IMAGE_LAYOUT_PRESENT_SRC_KHR) VK_ACCESS_MEMORY_READ_BIT VK_ACCESS_TRANSFER_WRITE_BIT)
                        VK_ACCESS_TRANSFER_READ_BIT
                        old new VK_QUEUE_FAMILY_IGNORED VK_QUEUE_FAMILY_IGNORED
                        (ptr-ref image-arr _VkImage image-index)
                        (vk-new make-VkImageSubresourceRange VK_IMAGE_ASPECT_COLOR_BIT 0 1 0 1)))
      (raw:vkCmdPipelineBarrier cb
                            VK_PIPELINE_STAGE_ALL_COMMANDS_BIT
                            VK_PIPELINE_STAGE_TRANSFER_BIT
                            0 0 #f 0 #f 1 b))
    (real-barrier VK_IMAGE_LAYOUT_PRESENT_SRC_KHR VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
    (define region (vk-new make-VkBufferImageCopy
                           0 0 0
                           (vk-new make-VkImageSubresourceLayers VK_IMAGE_ASPECT_COLOR_BIT 0 0 1)
                           (vk-new make-VkOffset3D 0 0 0)
                           (vk-new make-VkExtent3D (VkExtent2D-width extent) (VkExtent2D-height extent) 1)))
    (raw:vkCmdCopyImageToBuffer cb (ptr-ref image-arr _VkImage image-index)
                            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
                            (vector-ref readback 0) 1 region)
    (define b2 (vk-new make-VkImageMemoryBarrier
                       VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
                       #f VK_ACCESS_TRANSFER_READ_BIT 0
                       VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
                       VK_QUEUE_FAMILY_IGNORED VK_QUEUE_FAMILY_IGNORED
                       (ptr-ref image-arr _VkImage image-index)
                       (vk-new make-VkImageSubresourceRange VK_IMAGE_ASPECT_COLOR_BIT 0 1 0 1)))
    (raw:vkCmdPipelineBarrier cb VK_PIPELINE_STAGE_TRANSFER_BIT VK_PIPELINE_STAGE_ALL_COMMANDS_BIT
                          0 0 #f 0 #f 1 b2))
  (raw:vkEndCommandBuffer cb))

(define max-frames (if loop? 1000000000 FRAMES))
(define (fence-ptr) (let ([fp (vk-malloc _VkFence)]) (ptr-set! fp _VkFence in-flight) fp))
(let loop ([frame 0])
 (when (< frame max-frames)
  ;; 先等上一帧完成，再 acquire，保证 image-available 信号量不被复用
  (raw:vkWaitForFences device 1 (fence-ptr) VK_TRUE (* 10 1000000000))
  (raw:vkResetFences device 1 (fence-ptr))
  (define image-index-p (vk-malloc _uint32))
  (raw:vkAcquireNextImageKHR device swapchain (* 10 1000000000) image-available #f image-index-p)
  (define image-index (ptr-ref image-index-p _uint32))
  (record! image-index command-buffer)
  (define cb-p (vk-malloc _VkCommandBuffer))
  (ptr-set! cb-p _VkCommandBuffer command-buffer)
  (define wait-sem (vk-malloc _VkSemaphore 1))
  (ptr-set! wait-sem _VkSemaphore 0 image-available)
  (define wait-stage (vk-malloc _int32 1))
  (ptr-set! wait-stage _int32 0 VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT)
  (define sig-sem (vk-malloc _VkSemaphore 1))
  (ptr-set! sig-sem _VkSemaphore 0 (vector-ref render-finished-sems image-index))
  (define submit (vk-new make-VkSubmitInfo VK_STRUCTURE_TYPE_SUBMIT_INFO
                          #f 1 wait-sem wait-stage 1 cb-p 1 sig-sem))
  (raw:vkQueueSubmit queue 1 submit in-flight)
  (define swapchains (vk-malloc _VkSwapchainKHR 1))
  (ptr-set! swapchains _VkSwapchainKHR 0 swapchain)
  (define indices (vk-malloc _uint32 1))
  (ptr-set! indices _uint32 0 image-index)
  (define present (vk-new make-VkPresentInfoKHR VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
                           #f 1 sig-sem 1 swapchains indices #f))
  (raw:vkQueuePresentKHR queue present)
  (when (or (not loop?) (< frame 5))
    (printf "[ok] frame ~a: image ~a acquired/rendered/presented\n" frame image-index))
  (if loop?
      (begin (sleep 0.016)
             (unless (window-closed?) (loop (add1 frame))))
      (loop (add1 frame)))))

(raw:vkQueueWaitIdle queue)
(raw:vkDeviceWaitIdle device)
(printf "[ok] presented ~a frames\n" (if loop? "many" FRAMES))

;; ---------- readback check ----------
(when readback
  (define buf (vector-ref readback 0))
  (define mem (vector-ref readback 1))
  (define size (vector-ref readback 2))
  (define byte-p (vk-malloc _pointer))
  (raw:vkMapMemory device mem 0 size 0 byte-p)
  (define p (ptr-ref byte-p _pointer))
  (define cx (quotient (VkExtent2D-width extent) 2))
  (define cy (quotient (VkExtent2D-height extent) 2))
  (define off (* 4 (+ cx (* cy (VkExtent2D-width extent)))))
  (define b0 (ptr-ref p _uint8 off))
  (define b1 (ptr-ref p _uint8 (+ off 1)))
  (define b2 (ptr-ref p _uint8 (+ off 2)))
  (define b3 (ptr-ref p _uint8 (+ off 3)))
  (printf "[ok] center pixel = (~a ~a ~a ~a)\n" b0 b1 b2 b3)
  (when (and (not loop?) (< b0 30) (< b1 30) (< b2 30))
    (error 'triangle "center pixel looks like clear color, triangle not rendered"))
  (raw:vkUnmapMemory device mem)
  (raw:vkFreeMemory device mem #f)
  (raw:vkDestroyBuffer device buf #f))

;; ---------- cleanup ----------
(raw:vkDeviceWaitIdle device)
(raw:vkDestroyFence device in-flight #f)
(for ([s render-finished-sems]) (raw:vkDestroySemaphore device s #f))
(raw:vkDestroySemaphore device image-available #f)
(raw:vkDestroyCommandPool device command-pool #f)
(raw:vkDestroyPipeline device pipeline #f)
(raw:vkDestroyPipelineLayout device pipeline-layout #f)
(raw:vkDestroyShaderModule device frag-module #f)
(raw:vkDestroyShaderModule device vert-module #f)
(raw:vkDestroyRenderPass device render-pass #f)
(for ([fb framebuffers]) (raw:vkDestroyFramebuffer device fb #f))
(for ([iv image-views]) (raw:vkDestroyImageView device iv #f))
(raw:vkDestroySwapchainKHR device swapchain #f)
(raw:vkDestroyDevice device #f)
(raw:vkDestroySurfaceKHR instance surface #f)
(raw:vkDestroyInstance instance #f)
(void (XDestroyWindow dpy win))
(void (XCloseDisplay dpy))
(printf "[ok] done\n")
