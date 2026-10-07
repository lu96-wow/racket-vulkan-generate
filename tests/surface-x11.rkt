#lang racket/base
;; 扩展测试：VK_KHR_surface + VK_KHR_xlib_surface + VK_KHR_swapchain
(require vulkan
         ffi/unsafe
         ffi/unsafe/define)
(file-stream-buffer-mode (current-output-port) 'line)

;; 最小 X11 绑定（拿 Display* 和 root Window）
(define-ffi-definer define-x11 (ffi-lib "libX11" '("6" "")))
(define-x11 XOpenDisplay (_fun _pointer -> _pointer))
(define-x11 XDefaultScreen (_fun _pointer -> _int))
(define-x11 XRootWindow (_fun _pointer _int -> _ulong))
(define-x11 XCloseDisplay (_fun _pointer -> _int))

(define x11-exts (list #"VK_KHR_surface" #"VK_KHR_xlib_surface"))
(define ext-arr
  (let ()
    (define arr (vk-malloc _pointer (length x11-exts)))
    (for ([b x11-exts] [i (in-naturals)])
      (ptr-set! arr _pointer i (stable-bytes b)))
    arr))

(define-values (r1 instance)
  (vkCreateInstance
   (λ ()
     (define app (vk-new make-VkApplicationInfo VK_STRUCTURE_TYPE_APPLICATION_INFO
                         #f #f 0 #f 0 VK_API_VERSION_1_1))
     (vk-new make-VkInstanceCreateInfo VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
             #f 0 app 0 #f (length x11-exts) ext-arr))
   #f))
(vk-use-instance! instance)
(printf "[ok] instance = ~a\n" instance)

(define physical-device
  (let ()
    (define cnt (vk-malloc _uint32))
    (raw:vkEnumeratePhysicalDevices instance cnt #f)
    (define n (ptr-ref cnt _uint32))
    (define arr (vk-malloc _VkPhysicalDevice n))
    (raw:vkEnumeratePhysicalDevices instance cnt arr)
    (ptr-ref arr _VkPhysicalDevice)))

(define dpy (XOpenDisplay #f))
(unless dpy (error 'surface "cannot open X display"))
(define win (XRootWindow dpy (XDefaultScreen dpy)))
(printf "[ok] X display=~a root window=~a\n" dpy win)

(define-values (r2 surface)
  (vkCreateXlibSurfaceKHR instance
   (λ () (vk-new make-VkXlibSurfaceCreateInfoKHR
                 VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR #f 0 dpy win))
   #f))
(printf "[ok] xlib surface = ~a\n" surface)

(define queue-family-index
  (let ()
    (define cnt (vk-malloc _uint32))
    (raw:vkGetPhysicalDeviceQueueFamilyProperties physical-device cnt #f)
    (define n (ptr-ref cnt _uint32))
    (define arr (vk-malloc _VkQueueFamilyProperties n))
    (raw:vkGetPhysicalDeviceQueueFamilyProperties physical-device cnt arr)
    (for/fold ([acc #f]) ([i (in-range n)] #:break acc)
      (define p (ptr-ref arr _VkQueueFamilyProperties i))
      (if (and (> (VkQueueFamilyProperties-queueCount p) 0)
               (not (zero? (bitwise-and (VkQueueFamilyProperties-queueFlags p)
                                        VK_QUEUE_GRAPHICS_BIT))))
          i #f))))

(define supported
  (let ()
    (define out (vk-zero _VkBool32))
    (raw:vkGetPhysicalDeviceSurfaceSupportKHR physical-device queue-family-index surface out)
    (ptr-ref out _VkBool32)))
(printf "[ok] surface supported on queue family ~a: ~a\n" queue-family-index (not (zero? supported)))

(cond
  [(zero? supported)
   (printf "[skip] no presentation support\n")]
  [else
   ;; caps
   (define caps-p (vk-zero _VkSurfaceCapabilitiesKHR))
   (raw:vkGetPhysicalDeviceSurfaceCapabilitiesKHR physical-device surface caps-p)
   (define caps (ptr-ref caps-p _VkSurfaceCapabilitiesKHR))
   (printf "[ok] caps: minImageCount=~a currentExtent=~ax~a\n"
           (VkSurfaceCapabilitiesKHR-minImageCount caps)
           (VkExtent2D-width (VkSurfaceCapabilitiesKHR-currentExtent caps))
           (VkExtent2D-height (VkSurfaceCapabilitiesKHR-currentExtent caps)))

   ;; formats
   (define fmt-count-p (vk-malloc _uint32))
   (raw:vkGetPhysicalDeviceSurfaceFormatsKHR physical-device surface fmt-count-p #f)
   (define nfmt (ptr-ref fmt-count-p _uint32))
   (define fmt-arr (vk-malloc _VkSurfaceFormatKHR nfmt))
   (raw:vkGetPhysicalDeviceSurfaceFormatsKHR physical-device surface fmt-count-p fmt-arr)
   (printf "[ok] formats=~a first=(format ~a, colorspace ~a)\n" nfmt
           (VkSurfaceFormatKHR-format (ptr-ref fmt-arr _VkSurfaceFormatKHR 0))
           (VkSurfaceFormatKHR-colorSpace (ptr-ref fmt-arr _VkSurfaceFormatKHR 0)))

   ;; present modes
   (define pm-count-p (vk-malloc _uint32))
   (raw:vkGetPhysicalDeviceSurfacePresentModesKHR physical-device surface pm-count-p #f)
   (define npm (ptr-ref pm-count-p _uint32))
   (define pm-arr (vk-malloc _int32 npm))
   (raw:vkGetPhysicalDeviceSurfacePresentModesKHR physical-device surface pm-count-p pm-arr)
   (printf "[ok] present modes=~a\n" npm)

   ;; device + swapchain
   (define dev-exts (list #"VK_KHR_swapchain"))
   (define dev-ext-arr
     (let ()
       (define arr (vk-malloc _pointer (length dev-exts)))
       (for ([b dev-exts] [i (in-naturals)]) (ptr-set! arr _pointer i (stable-bytes b)))
       arr))
   (define-values (r3 device)
     (vkCreateDevice physical-device
      (λ ()
        (define prio (vk-malloc _float))
        (ptr-set! prio _float 1.0)
        (define qci (vk-new make-VkDeviceQueueCreateInfo
                            VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
                            #f 0 queue-family-index 1 prio))
        (vk-new make-VkDeviceCreateInfo VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                #f 0 1 qci 0 #f (length dev-exts) dev-ext-arr #f))
      #f))
   (vk-use-device! device)
   (printf "[ok] device = ~a\n" device)

   (define extent (VkSurfaceCapabilitiesKHR-currentExtent caps))
   (define fmt0 (ptr-ref fmt-arr _VkSurfaceFormatKHR 0))
   ;; compositeAlpha 必须是「一个」受支持的位，而不是整个 mask
   (define composite-mask (VkSurfaceCapabilitiesKHR-supportedCompositeAlpha caps))
   (define composite-alpha (bitwise-and composite-mask (- composite-mask)))
   (unless (positive? composite-alpha) (error 'surface "no composite alpha support"))
   (define-values (r4 swapchain)
     (vkCreateSwapchainKHR device
      (λ ()
        (vk-new make-VkSwapchainCreateInfoKHR
                VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
                #f 0 surface
                (max 2 (VkSurfaceCapabilitiesKHR-minImageCount caps))
                (VkSurfaceFormatKHR-format fmt0)
                (VkSurfaceFormatKHR-colorSpace fmt0)
                extent 1 VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
                VK_SHARING_MODE_EXCLUSIVE 0 #f
                (VkSurfaceCapabilitiesKHR-currentTransform caps)
                composite-alpha
                (ptr-ref pm-arr _int32 0) VK_TRUE #f))
      #f))
   (printf "[ok] swapchain = ~a\n" swapchain)

   (define img-count-p (vk-malloc _uint32))
   (raw:vkGetSwapchainImagesKHR device swapchain img-count-p #f)
   (define nimg (ptr-ref img-count-p _uint32))
   (define img-arr (vk-malloc _VkImage nimg))
   (raw:vkGetSwapchainImagesKHR device swapchain img-count-p img-arr)
   (printf "[ok] swapchain images = ~a\n" nimg)

   (vkDestroySwapchainKHR device swapchain #f)
   (vkDestroyDevice device #f)])

(vkDestroySurfaceKHR instance surface #f)
(vkDestroyInstance instance #f)
(void (XCloseDisplay dpy))
(printf "[ok] done\n")
