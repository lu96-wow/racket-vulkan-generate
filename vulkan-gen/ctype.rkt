#lang racket/base
;; ============================================================
;; C 类型 -> Racket ctype 映射 + struct/union 成员解析。
;; 只依赖注册表事实；不产出 define 形式（那在 emit-types.rkt）。
;; ============================================================

(require racket/list
         racket/string
         "xexpr.rkt"
         "vk-registry.rkt")

(provide base-ctype basetype-map platform-ctype
         base-c-type-name category-of ctype-of-type-name
         member-name members-of member-type-text member-signature member-text
         pointer-member? array-member? array-dims bitfield-member? bitfield-width
         member-base-name member-ctype-expr
         params-of pointer-param? param-ctype
         type-dependencies find-count-field
         (struct-out vk-cfield) (struct-out vk-bitgroup)
         struct-layout bitmask-64?
         current-unknown-type)

(define base-ctype
  (hash "void" '_void "char" '_byte "signed char" '_int8 "unsigned char" '_uint8
        "short" '_int16 "unsigned short" '_uint16 "int" '_int32 "unsigned int" '_uint32
        "long" '_int64 "unsigned long" '_uint64 "long long" '_int64 "unsigned long long" '_uint64
        "int8_t" '_int8 "uint8_t" '_uint8 "int16_t" '_int16 "uint16_t" '_uint16
        "int32_t" '_int32 "uint32_t" '_uint32 "int64_t" '_int64 "uint64_t" '_uint64
        "size_t" '_size "float" '_float "double" '_double "_Bool" '_bool))

(define basetype-map
  (hash "VkSampleMask" '_uint32 "VkBool32" '_uint32 "VkFlags" '_uint32
        "VkFlags64" '_uint64 "VkDeviceSize" '_uint64 "VkDeviceAddress" '_uint64
        "VkRemoteAddressNV" '_pointer))

;; 平台类型（vk.xml 里只有引用、没有定义；参考旧绑定手工映射）
(define platform-ctype
  (hash "Window" '_ulong "VisualID" '_ulong "RROutput" '_ulong
        "xcb_window_t" '_uint32 "xcb_visualid_t" '_uint32
        "zx_handle_t" '_uint32 "GgpStreamDescriptor" '_uint32 "GgpFrameToken" '_uint32
        "Display" '_pointer "xcb_connection_t" '_pointer
        "wl_display" '_pointer "wl_surface" '_pointer
        "OHNativeWindow" '_pointer "OHBufferHandle" '_pointer "OH_NativeBuffer" '_pointer
        "ANativeWindow" '_pointer "AHardwareBuffer" '_pointer "IOSurfaceRef" '_pointer
        "CAMetalLayer" '_pointer "NativeWindow" '_pointer
        "MTLDevice_id" '_pointer "MTLCommandQueue_id" '_pointer "MTLBuffer_id" '_pointer
        "MTLTexture_id" '_pointer "MTLSharedEvent_id" '_pointer "id" '_pointer
        ;; Win32
        "DWORD" '_uint32 "HANDLE" '_pointer "HINSTANCE" '_pointer
        "HMONITOR" '_pointer "HWND" '_pointer "LPCWSTR" '_pointer
        ;; DirectFB / NvSci / UBM
        "IDirectFB" '_pointer "_screen_buffer" '_pointer "_screen_window" '_pointer
        "NvSciBufAttrList" '_pointer "NvSciBufObj" '_pointer
        "NvSciSyncAttrList" '_pointer "NvSciSyncObj" '_pointer "ubm_device" '_pointer
        ;; 外部视频类型（C enum -> int32）
        "StdVideoAV1Level" '_int32 "StdVideoAV1Profile" '_int32
        "StdVideoH264LevelIdc" '_int32 "StdVideoH264ProfileIdc" '_int32
        "StdVideoH265LevelIdc" '_int32 "StdVideoH265ProfileIdc" '_int32
        "StdVideoVP9Level" '_int32 "StdVideoVP9Profile" '_int32))

(define (base-c-type-name s)
  (define toks (filter (λ (t) (and (not (string=? t ""))
                                   (not (member t '("const" "struct" "union" "enum" "volatile")))))
                       (regexp-split #px"[\\s*]+" (string-trim s))))
  (if (null? toks) "void" (last toks)))

(define (category-of reg nm)
  (define ty (hash-ref (registry-types-hash reg)
                       (if (symbol? nm) nm (string->symbol nm)) #f))
  (and ty (cat-of ty)))

;; ------------------------------------------------------------------
;; 未知类型审计：ctype-of-type-name 退化成 _pointer 时**通过回调上报**，
;; 状态由调用方（driver）持有——本模块无全局。
(define current-unknown-type (make-parameter #f))
(define (mark-unknown! nm)
  (define f (current-unknown-type))
  (when f (f nm))
  '_pointer)

(define (ctype-of-type-name reg nm)
  (cond
    [(hash-has-key? base-ctype nm) (hash-ref base-ctype nm)]
    [(hash-has-key? basetype-map nm) (hash-ref basetype-map nm)]
    [(hash-has-key? platform-ctype nm) (hash-ref platform-ctype nm)]
    [(hash-has-key? (registry-types-hash reg) (string->symbol nm))
     (case (category-of reg (string->symbol nm))
       [(struct union enum bitmask handle funcpointer) (string->symbol (format "_~a" nm))]
       [(basetype) (hash-ref basetype-map nm (λ () (mark-unknown! nm)))]
       [else (mark-unknown! nm)])]
    [else (mark-unknown! nm)]))

;; ------------------------------------------------------------------
;; 成员解析
(define (member-name m)
  (let ([n (find-first-by-tag 'name m)]) (and n (xtext n))))
(define (members-of ty)
  (filter api-ok? (find-all-by-tag 'member ty)))
(define (member-type-text m)
  (let ([t (find-first-by-tag 'type m)]) (if t (xtext t) "")))
;; 去掉 <name> 后的完整签名（用于判 *、数组、const）
(define (member-signature m)
  (define (walk x)
    (cond [(string? x) x]
          [(xelem? x) (if (eq? (xtag x) 'name) ""
                          (apply string-append (map walk (xcontent x))))]
          [else ""]))
  (apply string-append (map walk (xcontent m))))
(define (member-text m) (xtext m))
(define (pointer-member? m) (regexp-match? #px"\\*" (member-signature m)))
(define (array-member? m) (or (find-first-by-tag 'enum m)
                              (regexp-match? #px"\\[[0-9]+\\]" (member-signature m))))
;; 数组维度列表；支持多维（如 float matrix[3][4] -> (3 4)），符号维度用 symbol。
(define (array-dims m)
  (define e (find-first-by-tag 'enum m))
  (if e
      (list (string->symbol (xtext e)))
      (for/list ([d (regexp-match* #px"\\[([^\\]]+)\\]" (member-signature m) #:match-select cadr)])
        (or (string->number d) (string->symbol d)))))
(define (bitfield-member? m) (regexp-match? #px":\\s*[0-9]+" (member-text m)))
(define (bitfield-width m)
  (define mm (regexp-match #px":\\s*([0-9]+)" (member-text m)))
  (and mm (string->number (cadr mm))))
(define (member-base-name m) (base-c-type-name (member-type-text m)))

(define (member-ctype-expr reg m)
  (define base (member-base-name m))
  (cond
    [(pointer-member? m) '_pointer]
    [(array-member? m)
     (define dims (array-dims m))
     (if (null? dims) '_pointer `(_array ,(ctype-of-type-name reg base) ,@dims))]
    ;; 结构体里的函数指针成员用 _pointer：由 vk-callback 提供稳定指针，
    ;; 避免把同一 Racket 过程重复转成不同 trampoline 而丢失保活。
    [(eq? (category-of reg (string->symbol base)) 'funcpointer) '_pointer]
    [else (ctype-of-type-name reg base)]))

;; ------------------------------------------------------------------
;; 命令参数（<param>）解析；funcpointer 的 <proto>/<param> 也走这里。
(define (params-of c)
  (filter (λ (x) (and (xelem? x) (eq? (xtag x) 'param) (api-ok? x))) (xcontent c)))
(define (pointer-param? p) (regexp-match? #px"\\*" (member-signature p)))
(define (param-ctype reg p)
  (if (pointer-param? p) '_pointer (ctype-of-type-name reg (member-base-name p))))

;; by-value 依赖（原始类型名，用于拓扑排序/闭包）
(define (type-dependencies reg nm)
  (define ty (hash-ref (registry-types-hash reg) nm #f))
  (if (not ty) '()
      (let ([a (attr ty 'alias #f)])
        (cond
          ;; 任何带 alias 的类型都依赖目标类型（保证目标先定义、且被拉进闭包）
          [a (list (string->symbol a))]
          [else
           (case (cat-of ty)
             [(struct union)
              (for/list ([m (members-of ty)]
                         #:when (and (not (pointer-member? m)) (not (bitfield-member? m))))
                (string->symbol (member-base-name m)))]
             [(funcpointer)
              (define proto (find-first-by-tag 'proto ty))
              (define ret (and proto (member-base-name proto)))
              (define args (for/list ([p (params-of ty)] #:when (not (pointer-param? p)))
                             (string->symbol (member-base-name p))))
              (append (if ret (list (string->symbol ret)) '()) args)]
             [else '()])]))))

;; vkAllocate* 在 info 结构体里的 count 字段（例如 commandBufferCount）
(define (find-count-field reg info-base)
  (define ty (hash-ref (registry-types-hash reg) (string->symbol info-base) #f))
  (and ty
       (findf (λ (m) (regexp-match? #px"[Cc]ount$" (member-name m)))
              (members-of ty))))

;; ------------------------------------------------------------------
;; 位域布局：Racket define-cstruct 不支持 C 位域，故把「一个存储单元」内的
;; 连续位域打包成一个底层整型字段；另生成掩码/移位访问器。
(struct vk-cfield (name ctype) #:transparent)
;; bits：((member-name offset width) ...)，offset 是单元内位偏移
(struct vk-bitgroup (storage base-ctype bits) #:transparent)

;; 原子类型位宽（避免在生成期依赖 ffi/unsafe 的 ctype 值）
(define primitive-bits
  (hash "char" 8 "signed char" 8 "unsigned char" 8 "int8_t" 8 "uint8_t" 8 "_Bool" 8
        "short" 16 "unsigned short" 16 "int16_t" 16 "uint16_t" 16
        "int" 32 "unsigned int" 32 "int32_t" 32 "uint32_t" 32 "float" 32
        "VkSampleMask" 32 "VkBool32" 32 "VkFlags" 32
        "long" 64 "unsigned long" 64 "long long" 64 "unsigned long long" 64
        "int64_t" 64 "uint64_t" 64 "double" 64 "size_t" 64
        "VkFlags64" 64 "VkDeviceSize" 64 "VkDeviceAddress" 64))

;; bitmask 是 32 还是 64（与 emit-types 的 _VkX 定义一致）
(define (bitmask-64? reg ty)
  (or (regexp-match? #px"VkFlags64" (xtext ty))
      (let ([bv (attr ty 'bitvalues #f)])
        (and bv (let ([blk (findf (λ (b) (equal? (attr b 'name) bv))
                                  (registry-enums-blocks reg))])
                  (and blk (equal? (attr blk 'bitwidth) "64")))))))

(define (bitfield-unit-bits reg base)
  (cond
    [(hash-ref primitive-bits base #f)]
    [else
     (define ty (hash-ref (registry-types-hash reg) (string->symbol base) #f))
     (case (and ty (cat-of ty))
       [(bitmask) (if (bitmask-64? reg ty) 64 32)]
       [else 32])]))

;; 把一个 struct 的成员归约成：普通字段 / 位域打包单元（保持顺序与原布局）。
(define (struct-layout reg ty)
  (define members (filter member-name (members-of ty)))
  (define counter (box 0))
  (define (take-run ms unit-bits)
    ;; 从 ms 开头（全是位域）取到本单元填满为止
    (let inner ([ms ms] [off 0] [acc '()])
      (cond
        [(null? ms) (values (reverse acc) '())]
        [(not (bitfield-member? (car ms))) (values (reverse acc) ms)]
        [else
         (define w (bitfield-width (car ms)))
         (if (or (not w) (> (+ off w) unit-bits))
             (values (reverse acc) ms)
             (inner (cdr ms) (+ off w) (cons (list (member-name (car ms)) off w) acc)))])))
  (let loop ([ms members] [out '()])
    (cond
      [(null? ms) (reverse out)]
      [(bitfield-member? (car ms))
       (define base (member-base-name (car ms)))
       (define unit-bits (bitfield-unit-bits reg base))
       (define-values (bits rest) (take-run ms unit-bits))
       (define storage (string->symbol (format "_bits~a" (unbox counter))))
       (set-box! counter (add1 (unbox counter)))
       (loop rest (cons (vk-bitgroup storage (ctype-of-type-name reg base) bits) out))]
      [else
       (define m (car ms))
       (loop (cdr ms) (cons (vk-cfield (string->symbol (member-name m)) (member-ctype-expr reg m)) out))])))
