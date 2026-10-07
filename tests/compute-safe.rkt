#lang racket/base
;; ============================================================
;; 用“安全层”跑通 Vulkan 计算着色器：
;;   * 所有驱动可见内存都由 vk-new / vk-malloc / stable-bytes 分配（atomic-interior）
;;   * 所有对象用 vk-create-* / vk-allocate-* 创建（输入 arena 绑定到对象生命周期）
;;   * vk-destroy-* / vk-free-* 释放
;; ============================================================
(require vulkan
         ffi/unsafe
         racket/port
         racket/file
         racket/runtime-path)

(define-runtime-path here ".")

(define-cstruct _pixel ([r _float] [g _float] [b _float] [a _float]))

(define width 3200)
(define height 2400)
(define workgroup-size 32)
(define pixel-size 16)                       ; 4 * float
(define buffer-size (* pixel-size width height))

(define spv-bytes
  (call-with-input-file (build-path here "comp.spv") port->bytes))

;; ---------- instance ----------
(define-values (r1 instance)
  (vkCreateInstance
   (λ ()
     (define app (vk-new make-VkApplicationInfo VK_STRUCTURE_TYPE_APPLICATION_INFO
                         #f #"Compute" 0 #"racket-vulkan" 0 VK_API_VERSION_1_0))
     (vk-new make-VkInstanceCreateInfo VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
             #f 0 app 0 #f 0 #f))
   #f))
(void (register-vk-instance! instance))
(printf "[ok] instance = ~a\n" instance)

;; ---------- physical device / queue family ----------
(define physical-device
  (let ()
    (define cnt (vk-malloc _uint32))
    (raw:vkEnumeratePhysicalDevices instance cnt #f)
    (define n (ptr-ref cnt _uint32))
    (define arr (vk-malloc _VkPhysicalDevice n))
    (raw:vkEnumeratePhysicalDevices instance cnt arr)
    (ptr-ref arr _VkPhysicalDevice)))

(define queue-family-index
  (let ()
    (define cnt (vk-malloc _uint32))
    (raw:vkGetPhysicalDeviceQueueFamilyProperties physical-device cnt #f)
    (define n (ptr-ref cnt _uint32))
    (define arr (vk-malloc _VkQueueFamilyProperties n))
    (raw:vkGetPhysicalDeviceQueueFamilyProperties physical-device cnt arr)
    (define idx
      (for/fold ([acc #f]) ([i (in-range n)] #:break acc)
        (define p (ptr-ref arr _VkQueueFamilyProperties i))
        (if (and (> (VkQueueFamilyProperties-queueCount p) 0)
                 (not (zero? (bitwise-and (VkQueueFamilyProperties-queueFlags p)
                                          VK_QUEUE_COMPUTE_BIT))))
            i #f)))
    (unless idx (error 'compute "no compute queue family"))
    (printf "[ok] compute queue family = ~a\n" idx)
    idx))

;; ---------- device / queue ----------
(define-values (r2 device)
  (vkCreateDevice physical-device
   (λ ()
     (define prio (vk-malloc _float))
     (ptr-set! prio _float 1.0)
     (define qci (vk-new make-VkDeviceQueueCreateInfo VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
                         #f 0 queue-family-index 1 prio))
     (vk-new make-VkDeviceCreateInfo VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
             #f 0 1 qci 0 #f 0 #f #f))
   #f))
(void (register-vk-device! device))
(printf "[ok] device = ~a\n" device)

(define queue
  (let ()
    (define p (vk-malloc _VkQueue))
    (raw:vkGetDeviceQueue device queue-family-index 0 p)
    (ptr-ref p _VkQueue)))

;; ---------- storage buffer + memory ----------
(define-values (r3 buffer)
  (vkCreateBuffer device
   (λ ()
     (vk-new make-VkBufferCreateInfo VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
             #f 0 buffer-size VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
             VK_SHARING_MODE_EXCLUSIVE 0 #f))
   #f))

(define (memory-type-index type-bits properties)
  (define pdmp (vk-zero _VkPhysicalDeviceMemoryProperties))
  (raw:vkGetPhysicalDeviceMemoryProperties physical-device pdmp)
  (define mp (ptr-ref pdmp _VkPhysicalDeviceMemoryProperties))
  (or (for/fold ([acc #f])
                ([i (in-range (VkPhysicalDeviceMemoryProperties-memoryTypeCount mp))] #:break acc)
        (define mt (array-ref (VkPhysicalDeviceMemoryProperties-memoryTypes mp) i))
        (if (and (not (zero? (bitwise-and type-bits (arithmetic-shift 1 i))))
                 (= (bitwise-and (VkMemoryType-propertyFlags mt) properties) properties))
            i #f))
      (error 'compute "no suitable memory type")))

(define-values (r13 buffer-memory)
  (let ()
    (define req-p (vk-zero _VkMemoryRequirements))
    (raw:vkGetBufferMemoryRequirements device buffer req-p)
    (define req (ptr-ref req-p _VkMemoryRequirements))
    (vkAllocateMemory device
     (λ ()
       (vk-new make-VkMemoryAllocateInfo VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
               #f (VkMemoryRequirements-size req)
               (memory-type-index (VkMemoryRequirements-memoryTypeBits req)
                                  (bitwise-ior VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
                                               VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))))
     #f)))
(raw:vkBindBufferMemory device buffer buffer-memory 0)
(printf "[ok] buffer + memory\n")

;; ---------- descriptor set ----------
(define-values (r4 descriptor-set-layout)
  (vkCreateDescriptorSetLayout device
   (λ ()
     (define b (vk-new make-VkDescriptorSetLayoutBinding
                       0 VK_DESCRIPTOR_TYPE_STORAGE_BUFFER 1 VK_SHADER_STAGE_COMPUTE_BIT #f))
     (vk-new make-VkDescriptorSetLayoutCreateInfo VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
             #f 0 1 b))
   #f))

(define-values (r5 descriptor-pool)
  (vkCreateDescriptorPool device
   (λ ()
     (define s (vk-new make-VkDescriptorPoolSize VK_DESCRIPTOR_TYPE_STORAGE_BUFFER 2))
     (vk-new make-VkDescriptorPoolCreateInfo VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
             #f 0 2 1 s))
   #f))

(define-values (r6 descriptor-sets)
  (vkAllocateDescriptorSets device
   (λ ()
     (define l (vk-malloc _VkDescriptorSetLayout 2))
     (ptr-set! l _VkDescriptorSetLayout 0 descriptor-set-layout)
     (ptr-set! l _VkDescriptorSetLayout 1 descriptor-set-layout)
     (vk-new make-VkDescriptorSetAllocateInfo VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
             #f descriptor-pool 2 l))))
(define descriptor-set (vector-ref descriptor-sets 0))
(unless (= (vector-length descriptor-sets) 2) (error "expected 2 descriptor sets"))

(let ()
  (with-vk-arena
    (define dbi (vk-new make-VkDescriptorBufferInfo buffer 0 buffer-size))
    (define wds (vk-new make-VkWriteDescriptorSet VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                                                  #f descriptor-set 0 0 1
                                                  VK_DESCRIPTOR_TYPE_STORAGE_BUFFER #f dbi #f))
    (raw:vkUpdateDescriptorSets device 1 wds 0 #f))
  (void))
(printf "[ok] descriptor set\n")

;; ---------- pipeline ----------
(define-values (r7 shader-module)
  (vkCreateShaderModule device
   (λ ()
     (define code (stable-bytes spv-bytes))
     (vk-new make-VkShaderModuleCreateInfo VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
             #f 0 (bytes-length spv-bytes) code))
   #f))

(define-values (r8 pipeline-layout)
  (vkCreatePipelineLayout device
   (λ ()
     (define l (vk-malloc _VkDescriptorSetLayout))
     (ptr-set! l _VkDescriptorSetLayout descriptor-set-layout)
     (vk-new make-VkPipelineLayoutCreateInfo VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
             #f 0 1 l 0 #f))
   #f))

(define-values (r9 pipelines)
  (vkCreateComputePipelines device
   (λ ()
     (define name (stable-bytes #"main"))
     (define ssci (vk-new make-VkPipelineShaderStageCreateInfo
                          VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
                          #f 0 VK_SHADER_STAGE_COMPUTE_BIT shader-module name #f))
     (vector
      (vk-new make-VkComputePipelineCreateInfo VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
              #f 0 ssci pipeline-layout #f 0)
      (vk-new make-VkComputePipelineCreateInfo VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
              #f 0 ssci pipeline-layout #f 0)))
   #f #f))
(define pipeline (vector-ref pipelines 0))
(unless (= (vector-length pipelines) 2) (error "expected 2 pipelines"))
(printf "[ok] compute pipeline\n")

;; ---------- command buffer ----------
(define-values (r10 command-pool)
  (vkCreateCommandPool device
   (λ () (vk-new make-VkCommandPoolCreateInfo VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
                                              #f 0 queue-family-index))
   #f))

(define-values (r11 command-buffers)
  (vkAllocateCommandBuffers device
   (λ () (vk-new make-VkCommandBufferAllocateInfo VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
                                                  #f command-pool VK_COMMAND_BUFFER_LEVEL_PRIMARY 2))))
(define command-buffer (vector-ref command-buffers 0))
(unless (= (vector-length command-buffers) 2) (error "expected 2 command buffers"))

(define command-buffer-p (vk-malloc _VkCommandBuffer))

(let ()
  (with-vk-arena
    (define cbbi (vk-new make-VkCommandBufferBeginInfo VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
                                                        #f VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT #f))
    (raw:vkBeginCommandBuffer command-buffer cbbi)
    (raw:vkCmdBindPipeline command-buffer VK_PIPELINE_BIND_POINT_COMPUTE pipeline)
    (define sets (vk-malloc _VkDescriptorSet))
    (ptr-set! sets _VkDescriptorSet descriptor-set)
    (raw:vkCmdBindDescriptorSets command-buffer VK_PIPELINE_BIND_POINT_COMPUTE pipeline-layout
                             0 1 sets 0 #f)
    (raw:vkCmdDispatch command-buffer
                   (quotient width workgroup-size)
                   (quotient height workgroup-size)
                   1)
    (raw:vkEndCommandBuffer command-buffer))
  (void))

;; ---------- submit + wait ----------
(define-values (r12 fence)
  (vkCreateFence device
   (λ () (vk-new make-VkFenceCreateInfo VK_STRUCTURE_TYPE_FENCE_CREATE_INFO #f 0))
   #f))

(let ()
  (with-vk-arena
    (define cb (vk-malloc _VkCommandBuffer))
    (ptr-set! cb _VkCommandBuffer command-buffer)
    (define si (vk-new make-VkSubmitInfo VK_STRUCTURE_TYPE_SUBMIT_INFO
                                         #f 0 #f #f 1 cb 0 #f))
    (define fences (vk-malloc _VkFence))
    (ptr-set! fences _VkFence fence)
    (raw:vkQueueSubmit queue 1 si fence)
    (raw:vkWaitForFences device 1 fences VK_TRUE (* 120 1000000000)))
  (void))
(printf "[ok] submitted + waited\n")

;; ---------- read back ----------
(let ()
  (define byte-p (vk-malloc _pointer))
  (raw:vkMapMemory device buffer-memory 0 buffer-size 0 byte-p)
  (define pixel-p (ptr-ref byte-p _pixel-pointer))
  (define out (build-path here "compute-safe.rgba"))
  (call-with-output-file out #:exists 'replace
    (λ (port)
      (for ([i (in-range (* width height))])
        (define px (ptr-ref pixel-p _pixel i))
        (define (cvt v) (inexact->exact (truncate (* 255.0 v))))
        (write-byte (cvt (pixel-r px)) port)
        (write-byte (cvt (pixel-g px)) port)
        (write-byte (cvt (pixel-b px)) port)
        (write-byte (cvt (pixel-a px)) port))))
  (raw:vkUnmapMemory device buffer-memory)
  (printf "[ok] wrote ~a (~a bytes)\n" out (file-size out)))

;; ---------- cleanup ----------
(vkFreeMemory device buffer-memory #f)
(vkDestroyBuffer device buffer #f)
(vkDestroyShaderModule device shader-module #f)
(vkDestroyDescriptorPool device descriptor-pool #f)
(vkDestroyDescriptorSetLayout device descriptor-set-layout #f)
(vkDestroyPipelineLayout device pipeline-layout #f)
(for ([p pipelines]) (vkDestroyPipeline device p #f))
(vkDestroyCommandPool device command-pool #f)
(vkDestroyFence device fence #f)
(vkDestroyDevice device #f)
(vkDestroyInstance instance #f)
(printf "[ok] done\n")
