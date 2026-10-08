#lang racket/base
(require vulkan/unsafe ffi/unsafe)
(define p (malloc _VkDebugUtilsMessengerEXT))
(printf "about to call vkCreateDebugUtilsMessengerEXT (not loader-exported)\n")
(with-handlers ([exn:fail? (λ (e) (printf "CAUGHT: ~a\n" (exn-message e)))])
  (vkCreateDebugUtilsMessengerEXT #f #f #f p))
