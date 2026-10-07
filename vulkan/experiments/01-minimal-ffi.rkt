#lang racket/base
(require ffi/unsafe ffi/unsafe/define)
(define-ffi-definer define-vk (ffi-lib "libvulkan" '("1" "")))
(define-vk vkEnumerateInstanceVersion (_fun (ver : (_ptr o _uint32)) -> (result : _int) -> (values result ver)))
(define-values (rc ver) (vkEnumerateInstanceVersion))
(printf "[ok] rc=~a version=0x~x => ~a.~a.~a~%" rc ver
        (bitwise-and (arithmetic-shift ver -22) #x3ff)
        (bitwise-and (arithmetic-shift ver -12) #x3ff)
        (bitwise-and ver #xfff))
(define _VkStructureType (_enum '(VK_STRUCTURE_TYPE_APPLICATION_INFO = 0)))
(define-cstruct _VkApplicationInfo
  ([sType _VkStructureType] [pNext _pointer]
   [pApplicationName _string/utf-8] [applicationVersion _uint32]
   [pEngineName _string/utf-8] [engineVersion _uint32] [apiVersion _uint32]))
(define ai (make-VkApplicationInfo 'VK_STRUCTURE_TYPE_APPLICATION_INFO #f "Hi" 0 "E" 0 #x00400000))
(printf "[ok] cstruct size=~a name=~a~%" (ctype-sizeof _VkApplicationInfo) (VkApplicationInfo-pApplicationName ai))
(define-vk vkGetInstanceProcAddr (_fun _pointer _string -> _pointer))
(printf "[ok] GIPA(vkCreateInstance)=~a  GIPA(vkCmdDraw)=~a~%"
        (vkGetInstanceProcAddr #f "vkCreateInstance") (vkGetInstanceProcAddr #f "vkCmdDraw"))
