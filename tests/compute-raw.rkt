#lang racket/base
;; ============================================================
;; 用“新自动生成绑定”跑通 Vulkan 计算着色器（llvmpipe）
;; 改编自 SimonLSchlee/racket-vulkan examples/mandelbrot（MIT）
;;
;; 与新绑定的差异：
;;   * enum/bitmask 用整数常量（不再是符号）
;;   * 命令经 global/instance/device 分派表加载
;;   * 需要 register-vk-instance! / register-vk-device!
;; ============================================================
(require vulkan/unsafe
         ffi/unsafe
         racket/port
         racket/file
         racket/runtime-path)

(define-runtime-path here ".")

;; ---------- helpers ----------
(define (make-zero _t [_pointer-type #f])
  (define size (ctype-sizeof _t))
  (define p (malloc 'atomic-interior size))
  (memset p 0 size)
  (cpointer-push-tag! p _t)
  (if _pointer-type (cast p _pointer _pointer-type) p))

(define (create _t f)
  (define p (malloc 'atomic-interior _t))
  (f p)
  (ptr-ref p _t))

(define-cstruct _pixel ([r _float] [g _float] [b _float] [a _float]))

;; ---------- instance ----------
(define (make-instance)
  (define app (make-VkApplicationInfo VK_STRUCTURE_TYPE_APPLICATION_INFO
                                      #f #"Compute" 0 #"racket-vulkan" 0 VK_API_VERSION_1_0))
  (define ici (make-VkInstanceCreateInfo VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                                         #f 0 app 0 #f 0 #f))
  (create _VkInstance (λ (p) (vkCreateInstance ici #f p))))

(define instance (make-instance))
(void (register-vk-instance! instance))
(printf "[ok] instance = ~a\n" instance)

;; ---------- physical device ----------
(define (find-physical-device)
  (define cnt (malloc 'atomic-interior _uint32))
  (vkEnumeratePhysicalDevices instance cnt #f)
  (define n (ptr-ref cnt _uint32))
  (define arr (malloc 'atomic-interior (* n (ctype-sizeof _VkPhysicalDevice))))
  (vkEnumeratePhysicalDevices instance cnt arr)
  (ptr-ref arr _VkPhysicalDevice))

(define physical-device (find-physical-device))

;; ---------- queue family (compute) ----------
(define (compute-queue-family-index)
  (define cnt (malloc 'atomic-interior _uint32))
  (vkGetPhysicalDeviceQueueFamilyProperties physical-device cnt #f)
  (define n (ptr-ref cnt _uint32))
  (define arr (malloc 'atomic-interior (* n (ctype-sizeof _VkQueueFamilyProperties))))
  (vkGetPhysicalDeviceQueueFamilyProperties physical-device cnt arr)
  (define idx
    (for/fold ([acc #f]) ([i (in-range n)] #:break acc)
      (define props (ptr-ref arr _VkQueueFamilyProperties i))
      (if (and (> (VkQueueFamilyProperties-queueCount props) 0)
               (not (zero? (bitwise-and (VkQueueFamilyProperties-queueFlags props)
                                        VK_QUEUE_COMPUTE_BIT))))
          i #f)))
  (unless idx (error 'compute "no compute queue family"))
  (printf "[ok] compute queue family = ~a\n" idx)
  idx)

(define queue-family-index (compute-queue-family-index))

;; ---------- logical device + queue ----------
(define (make-logical-device)
  (define prio (malloc 'atomic-interior _float))
  (ptr-set! prio _float 1.0)
  (define qci (make-VkDeviceQueueCreateInfo VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
                                            #f 0 queue-family-index 1 prio))
  (define dci (make-VkDeviceCreateInfo VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                                       #f 0 1 qci 0 #f 0 #f #f))
  (create _VkDevice (λ (p) (vkCreateDevice physical-device dci #f p))))

(define device (make-logical-device))
(void (register-vk-device! device))
(printf "[ok] device = ~a\n" device)

(define queue (let ()
                (define p (malloc 'atomic-interior _VkQueue))
                (vkGetDeviceQueue device queue-family-index 0 p)
                (ptr-ref p _VkQueue)))

;; ---------- storage buffer + memory ----------
(define width 3200)
(define height 2400)
(define workgroup-size 32)
(define buffer-size (* (ctype-sizeof _pixel) width height))

(define (make-buffer)
  (define bci (make-VkBufferCreateInfo VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
                                       #f 0 buffer-size VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
                                       VK_SHARING_MODE_EXCLUSIVE 0 #f))
  (create _VkBuffer (λ (p) (vkCreateBuffer device bci #f p))))

(define buffer (make-buffer))

(define (find-memory-type type-bits properties)
  (define pdmp (make-zero _VkPhysicalDeviceMemoryProperties))
  (vkGetPhysicalDeviceMemoryProperties physical-device pdmp)
  (define p (ptr-ref pdmp _VkPhysicalDeviceMemoryProperties))
  (or (for/fold ([acc #f]) ([i (in-range (VkPhysicalDeviceMemoryProperties-memoryTypeCount p))] #:break acc)
        (define mt (array-ref (VkPhysicalDeviceMemoryProperties-memoryTypes p) i))
        (if (and (not (zero? (bitwise-and type-bits (arithmetic-shift 1 i))))
                 (= (bitwise-and (VkMemoryType-propertyFlags mt) properties) properties))
            i #f))
      (error 'compute "no suitable memory type")))

(define (allocate-buffer-memory)
  (define req (make-zero _VkMemoryRequirements))
  (vkGetBufferMemoryRequirements device buffer req)
  (define r (ptr-ref req _VkMemoryRequirements))
  (define mai (make-VkMemoryAllocateInfo VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
                                         #f (VkMemoryRequirements-size r)
                                         (find-memory-type (VkMemoryRequirements-memoryTypeBits r)
                                                           (bitwise-ior VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
                                                                        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))))
  (define mem (create _VkDeviceMemory (λ (p) (vkAllocateMemory device mai #f p))))
  (vkBindBufferMemory device buffer mem 0)
  mem)

(define buffer-memory (allocate-buffer-memory))
(printf "[ok] buffer + memory\n")

;; ---------- descriptor set ----------
(define (make-descriptor-set-layout)
  (define dslb (make-zero _VkDescriptorSetLayoutBinding))
  (define b (ptr-ref dslb _VkDescriptorSetLayoutBinding))
  (set-VkDescriptorSetLayoutBinding-binding! b 0)
  (set-VkDescriptorSetLayoutBinding-descriptorType! b VK_DESCRIPTOR_TYPE_STORAGE_BUFFER)
  (set-VkDescriptorSetLayoutBinding-descriptorCount! b 1)
  (set-VkDescriptorSetLayoutBinding-stageFlags! b VK_SHADER_STAGE_COMPUTE_BIT)
  (define dslci (make-VkDescriptorSetLayoutCreateInfo VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
                                                      #f 0 1 dslb))
  (define layout-p (malloc 'atomic-interior _VkDescriptorSetLayout))
  (vkCreateDescriptorSetLayout device dslci #f layout-p)
  (values dslb layout-p (ptr-ref layout-p _VkDescriptorSetLayout)))

(define-values (dslb-p descriptor-set-layout-p descriptor-set-layout) (make-descriptor-set-layout))

(define (make-descriptor-pool)
  (define dps (make-zero _VkDescriptorPoolSize))
  (set-VkDescriptorPoolSize-type! (ptr-ref dps _VkDescriptorPoolSize) VK_DESCRIPTOR_TYPE_STORAGE_BUFFER)
  (set-VkDescriptorPoolSize-descriptorCount! (ptr-ref dps _VkDescriptorPoolSize) 1)
  (define dpci (make-VkDescriptorPoolCreateInfo VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
                                                #f 0 1 1 dps))
  (create _VkDescriptorPool (λ (p) (vkCreateDescriptorPool device dpci #f p))))

(define descriptor-pool (make-descriptor-pool))

(define (make-descriptor-set)
  (define dsai (make-VkDescriptorSetAllocateInfo VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
                                                 #f descriptor-pool 1 descriptor-set-layout-p))
  (define p (malloc 'atomic-interior _VkDescriptorSet))
  (vkAllocateDescriptorSets device dsai p)
  p)

(define descriptor-set-p (make-descriptor-set))

(define (connect-buffer)
  (define dbi (make-zero _VkDescriptorBufferInfo))
  (define d (ptr-ref dbi _VkDescriptorBufferInfo))
  (set-VkDescriptorBufferInfo-buffer! d buffer)
  (set-VkDescriptorBufferInfo-offset! d 0)
  (set-VkDescriptorBufferInfo-range! d buffer-size)
  (define wds (make-zero _VkWriteDescriptorSet))
  (define w (ptr-ref wds _VkWriteDescriptorSet))
  (set-VkWriteDescriptorSet-sType! w VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET)
  (set-VkWriteDescriptorSet-dstSet! w (ptr-ref descriptor-set-p _VkDescriptorSet))
  (set-VkWriteDescriptorSet-dstBinding! w 0)
  (set-VkWriteDescriptorSet-dstArrayElement! w 0)
  (set-VkWriteDescriptorSet-descriptorCount! w 1)
  (set-VkWriteDescriptorSet-descriptorType! w VK_DESCRIPTOR_TYPE_STORAGE_BUFFER)
  (set-VkWriteDescriptorSet-pImageInfo! w #f)
  (set-VkWriteDescriptorSet-pBufferInfo! w dbi)
  (set-VkWriteDescriptorSet-pTexelBufferView! w #f)
  (vkUpdateDescriptorSets device 1 wds 0 #f))

(connect-buffer)
(printf "[ok] descriptor set\n")

;; ---------- pipeline ----------
(define (read-spv)
  (call-with-input-file (build-path here "comp.spv") port->bytes))

(define spv-bytes (read-spv))
;; 用非移动内存保存 SPIR-V，防止驱动惰性引用时被 GC 移动/回收（见 stable-bytes 注释）
(define spv-buf (stable-bytes spv-bytes))

(define (make-shader-module)
  (define smci (make-VkShaderModuleCreateInfo VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
                                              #f 0 (bytes-length spv-bytes) spv-buf))
  (create _VkShaderModule (λ (p) (vkCreateShaderModule device smci #f p))))

(define shader-module (make-shader-module))

(define (make-pipeline-layout)
  (define plci (make-VkPipelineLayoutCreateInfo VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
                                                #f 0 1 descriptor-set-layout-p 0 #f))
  (create _VkPipelineLayout (λ (p) (vkCreatePipelineLayout device plci #f p))))

(define pipeline-layout (make-pipeline-layout))

(define entry-name-buf (stable-bytes #"main"))

(define (make-compute-pipeline)
  (define ssci (make-VkPipelineShaderStageCreateInfo VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
                                                     #f 0 VK_SHADER_STAGE_COMPUTE_BIT shader-module
                                                     entry-name-buf #f))
  (define pci (make-VkComputePipelineCreateInfo VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
                                                #f 0 ssci pipeline-layout #f 0))
  (create _VkPipeline (λ (p) (vkCreateComputePipelines device #f 1 pci #f p))))

(define pipeline (make-compute-pipeline))
(printf "[ok] compute pipeline\n")

;; ---------- command buffer ----------
(define (make-command-pool)
  (define cpci (make-VkCommandPoolCreateInfo VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
                                             #f 0 queue-family-index))
  (create _VkCommandPool (λ (p) (vkCreateCommandPool device cpci #f p))))

(define command-pool (make-command-pool))

(define (make-command-buffer)
  (define cbai (make-VkCommandBufferAllocateInfo VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
                                                 #f command-pool VK_COMMAND_BUFFER_LEVEL_PRIMARY 1))
  (define p (malloc 'atomic-interior _VkCommandBuffer))
  (vkAllocateCommandBuffers device cbai p)
  (values p (ptr-ref p _VkCommandBuffer)))

(define-values (command-buffer-p command-buffer) (make-command-buffer))

(define (record!)  (define cbbi (make-VkCommandBufferBeginInfo VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
                                              #f VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT #f))
  (vkBeginCommandBuffer command-buffer cbbi)
  (vkCmdBindPipeline command-buffer VK_PIPELINE_BIND_POINT_COMPUTE pipeline)
  (vkCmdBindDescriptorSets command-buffer VK_PIPELINE_BIND_POINT_COMPUTE pipeline-layout
                           0 1 descriptor-set-p 0 #f)
  (vkCmdDispatch command-buffer
                 (quotient width workgroup-size)
                 (quotient height workgroup-size)
                 1)
  (vkEndCommandBuffer command-buffer))

(record!)

(define (submit-and-wait)
  (define si (make-VkSubmitInfo VK_STRUCTURE_TYPE_SUBMIT_INFO #f 0 #f #f 1 command-buffer-p 0 #f))
  (define fence (create _VkFence (λ (p)
                                   (define fci (make-VkFenceCreateInfo VK_STRUCTURE_TYPE_FENCE_CREATE_INFO #f 0))
                                   (vkCreateFence device fci #f p))))
  (define fence-p (malloc 'atomic-interior _VkFence))
  (ptr-set! fence-p _VkFence fence)
  (vkQueueSubmit queue 1 si fence)
  (vkWaitForFences device 1 fence-p VK_TRUE (* 120 1000000000))
  (vkDestroyFence device fence #f))

(submit-and-wait)
(printf "[ok] submitted + waited\n")

;; ---------- read back ----------
(define (dump-output)
  (define byte-p (malloc 'atomic-interior _pointer))
  (vkMapMemory device buffer-memory 0 buffer-size 0 byte-p)
  (define pixel-p (ptr-ref byte-p _pixel-pointer))
  (define out (build-path here "compute.rgba"))
  (call-with-output-file out #:exists 'replace
    (λ (port)
      (for ([i (in-range (* width height))])
        (define px (ptr-ref pixel-p _pixel i))
        (define (cvt v) (inexact->exact (truncate (* 255.0 v))))
        (write-byte (cvt (pixel-r px)) port)
        (write-byte (cvt (pixel-g px)) port)
        (write-byte (cvt (pixel-b px)) port)
        (write-byte (cvt (pixel-a px)) port))))
  (vkUnmapMemory device buffer-memory)
  (printf "[ok] wrote ~a (~a bytes)\n" out (file-size out)))

(dump-output)

;; ---------- cleanup ----------
(vkFreeMemory device buffer-memory #f)
(vkDestroyBuffer device buffer #f)
(vkDestroyShaderModule device shader-module #f)
(vkDestroyDescriptorPool device descriptor-pool #f)
(vkDestroyDescriptorSetLayout device descriptor-set-layout #f)
(vkDestroyPipelineLayout device pipeline-layout #f)
(vkDestroyPipeline device pipeline #f)
(vkDestroyCommandPool device command-pool #f)
(vkDestroyDevice device #f)
(vkDestroyInstance instance #f)
(printf "[ok] done\n")
