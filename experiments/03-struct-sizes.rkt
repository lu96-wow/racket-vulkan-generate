#lang racket/base
(require vulkan/unsafe ffi/unsafe racket/format)
(define-syntax-rule (report (n ...))
  (for ([p (in-list (list (cons 'n n) ...))])
    (printf "~a ~a\n" (~a (car p) #:min-width 46) (ctype-sizeof (cdr p)))))
(report (_VkApplicationInfo _VkInstanceCreateInfo _VkPhysicalDeviceProperties _VkPhysicalDeviceLimits
    _VkPhysicalDeviceSparseProperties _VkPhysicalDeviceMemoryProperties _VkPhysicalDeviceFeatures
    _VkClearColorValue _VkClearDepthStencilValue _VkVertexInputBindingDescription
    _VkVertexInputAttributeDescription _VkPipelineVertexInputStateCreateInfo _VkAttachmentDescription
    _VkDescriptorSetLayoutBinding _VkDescriptorPoolSize _VkGraphicsPipelineCreateInfo
    _VkComputePipelineCreateInfo _VkSubmitInfo _VkPresentInfoKHR _VkSwapchainCreateInfoKHR
    _VkImageCreateInfo _VkBufferCreateInfo _VkExtent3D _VkViewport _VkRect2D
    _VkSpecializationInfo _VkPipelineShaderStageCreateInfo _VkDebugUtilsMessengerCreateInfoEXT
    _VkBaseInStructure _VkBaseOutStructure))
