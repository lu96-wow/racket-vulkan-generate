#lang racket/base
;; ============================================================
;; vk.xml -> Racket FFI bindings generator
;;
;; 参考 racket-opengl 的 readspec.rkt 思路：
;;   * 类型映射表把 C 类型映射到 Racket ctype
;;   * 生成 generated/constants.inc / types.inc / commands.inc / safe.inc
;;   * 运行时（base.rkt / safe.rkt）提供 define-vk 宏、分派加载器、所有权
;;
;; 用法：
;;   racket vulkan/generate.rkt [vk.xml] [out-dir] [feature] [ext1,ext2,...]
;; 默认：vulkan/registry/vk-1.4.363.xml  vulkan/generated  VK_VERSION_1_0  ""
;; ============================================================

(require xml
         racket/list
         racket/string
         racket/hash
         racket/match
         racket/path
         racket/file
         racket/runtime-path
         "api-facts.rkt"
         "gen/emit.rkt")

;; ------------------------------------------------------------------
;; 0. 参数（默认路径相对于本文件所在目录）
(define-runtime-path here ".")
(define args (current-command-line-arguments))
(define in-xml    (if (>= (vector-length args) 1) (vector-ref args 0)
                      (build-path here "registry" "vk-1.4.363.xml")))
(define out-dir   (if (>= (vector-length args) 2) (vector-ref args 1)
                      (build-path here "generated")))
(define target-feature (if (>= (vector-length args) 3) (vector-ref args 2) "VK_VERSION_1_0"))
(define target-extensions (if (>= (vector-length args) 4) (vector-ref args 3) ""))
(make-directory* out-dir)

;; ------------------------------------------------------------------
;; 1. 极简 xexpr 工具
(define (xelem? x) (and (pair? x) (symbol? (car x))))
(define (xtag x) (car x))
(define (xattrs x) (let ([a (and (pair? (cdr x)) (cadr x))])
                     (if (and (list? a) (andmap pair? a)) a '())))
(define (xcontent x) (if (and (pair? (cdr x)) (list? (cadr x)) (andmap pair? (cadr x)))
                         (cddr x) (cdr x)))
(define (attr x name [default #f])
  (let ([p (assq name (xattrs x))]) (if p (cadr p) default)))
(define (find-all-by-tag t x)
  (let loop ([x x])
    (cond [(xelem? x)
           (append (if (eq? (xtag x) t) (list x) '())
                   (append-map loop (xcontent x)))]
          [else '()])))
(define (find-first-by-tag t x)
  (let loop ([x x])
    (cond [(xelem? x) (or (and (eq? (xtag x) t) x) (ormap loop (xcontent x)))]
          [else #f])))
(define (text-of x)
  (cond [(string? x) x]
        [(xelem? x) (apply string-append (map text-of (xcontent x)))]
        [else ""]))
(define (xtext x) (string-trim (text-of x)))
(define (type-name ty)
  (or (attr ty 'name)
      (let ([n (find-first-by-tag 'name ty)]) (and n (xtext n)))))
(define (cat-of ty) (let ([c (attr ty 'category #f)]) (and c (string->symbol c))))
(define (api-ok? x)
  (define a (attr x 'api #f))
  (or (not a) (and (member "vulkan" (string-split a ",")) #t)))

;; ------------------------------------------------------------------
;; 2. 读注册表
(define registry
  (xml->xexpr (document-element (read-xml (open-input-file in-xml)))))

(define types-hash (make-hasheqv))
(for ([ty (find-all-by-tag 'type (find-first-by-tag 'types registry))])
  (define cat (cat-of ty))
  (define nm (type-name ty))
  (when (and nm (not (eq? cat 'include)) (api-ok? ty))
    (hash-set! types-hash (string->symbol nm) ty)))

(define enums-blocks (find-all-by-tag 'enums registry))
(define commands-list (find-all-by-tag 'command (find-first-by-tag 'commands registry)))
(define features-list (find-all-by-tag 'feature registry))
(define extensions-list (find-all-by-tag 'extension (find-first-by-tag 'extensions registry)))

(define (command-name c)
  (or (let ([p (find-first-by-tag 'proto c)])
        (and p (let ([n (find-first-by-tag 'name p)]) (and n (xtext n)))))
      ;; alias 命令没有 <proto>，只有 name 属性
      (attr c 'name)))
(define commands-hash (make-hasheqv))
(for ([c commands-list])
  (define n (command-name c))
  (when n (hash-set! commands-hash (string->symbol n) c)))
;; alias 命令（只有 alias="目标"，无 <proto>/<param>）解析到目标命令元素；
;; 生成时沿用目标的签名，但保留 alias 自己的名字。
(define (resolve-command c)
  (define a (attr c 'alias #f))
  (if a (or (hash-ref commands-hash (string->symbol a) #f) c) c))

;; ------------------------------------------------------------------
;; 3. feature 依赖闭包
(define (split-depends s)
  (if (or (not s) (string=? s "")) '() (string-split s "+")))
(define (feature-by-name n)
  (findf (λ (f) (equal? (attr f 'name) n)) features-list))
(define (feature-closure name)
  (let loop ([todo (list name)] [seen '()])
    (cond [(null? todo) (reverse seen)]
          [(member (car todo) seen) (loop (cdr todo) seen)]
          [else
           (define f (feature-by-name (car todo)))
           (loop (append (split-depends (and f (attr f 'depends))) (cdr todo))
                 (cons (car todo) seen))])))
(define (collect-requires feature-names)
  (define cmds '()) (define tys '())
  (for ([fn feature-names])
    (define f (feature-by-name fn))
    (when f
      (for ([req (find-all-by-tag 'require f)])
        (for ([ch (xcontent req)])
          (when (xelem? ch)
            (case (xtag ch)
              [(command) (set! cmds (cons (attr ch 'name) cmds))]
              [(type)    (set! tys  (cons (attr ch 'name) tys))]))))))
  (values (reverse cmds) (reverse tys)))

(define (extension-by-name n)
  (findf (λ (e) (equal? (attr e 'name) n)) extensions-list))
(define (extension-includable? e)
  (and (not (equal? (attr e 'provisional #f) "true"))
       (not (equal? (attr e 'supported #f) "disabled"))
       (api-ok? e)))
(define (extension-closure names)
  (let loop ([todo names] [seen '()])
    (cond [(null? todo) (reverse seen)]
          [(member (car todo) seen) (loop (cdr todo) seen)]
          [(or (not (extension-by-name (car todo)))
               (not (extension-includable? (extension-by-name (car todo)))))
           (loop (cdr todo) seen)]
          [else
           (define e (extension-by-name (car todo)))
           (loop (append (split-depends (attr e 'depends #f)) (cdr todo))
                 (cons (car todo) seen))])))
(define (collect-extension-requires names)
  (define cmds '()) (define tys '()) (define ens '())
  (for ([en names])
    (define e (extension-by-name en))
    (when e
      (for ([req (find-all-by-tag 'require e)])
        (for ([ch (xcontent req)])
          (when (xelem? ch)
            (case (xtag ch)
              [(command) (set! cmds (cons (attr ch 'name) cmds))]
              [(type)    (set! tys  (cons (attr ch 'name) tys))]
              [(enum)    (set! ens  (cons (cons (attr e 'number) ch) ens))]))))))
  (values (reverse cmds) (reverse tys) (reverse ens)))

;; ------------------------------------------------------------------
;; 4. 常量
(define closure (feature-closure target-feature))
(define ext-closure
  (extension-closure (if (string=? target-extensions "")
                         '()
                         (filter (λ (s) (not (string=? s ""))) (string-split target-extensions ",")))))
(define-values (feat-cmds feat-types) (collect-requires closure))
(define-values (ext-cmds ext-types ext-enums) (collect-extension-requires ext-closure))
(define wanted-cmds (append feat-cmds ext-cmds))
(define wanted-types (append feat-types ext-types))
(eprintf "extensions: ~a\n" ext-closure)
(define (mask-of bits) (- (arithmetic-shift 1 bits) 1))
(define (strip-parens s)
  (define t (string-trim s))
  (if (and (>= (string-length t) 2)
           (char=? (string-ref t 0) #\()
           (char=? (string-ref t (sub1 (string-length t))) #\)))
      (strip-parens (substring t 1 (sub1 (string-length t))))
      t))
(define (parse-c-int s)
  (define t (strip-parens s))
  (cond
    [(regexp-match #px"^0[xX]([0-9a-fA-F]+)$" t) => (λ (m) (string->number (cadr m) 16))]
    [(regexp-match #px"^-?[0-9]+$" t) => (λ (m) (string->number t))]
    [(regexp-match #px"^~0(ULL|LL|UL|U|L)?(-([0-9]+))?$" t)
     => (λ (m)
          (define suffix (or (cadr m) ""))
          (define bits (if (member suffix '("ULL" "LL" "UL")) 64 32))
          (define base (mask-of bits))
          (define sub (if (list-ref m 3) (string->number (list-ref m 3)) 0))
          (- base sub))]
    [(regexp-match #px"^([0-9]*\\.?[0-9]+)[fF]$" t) => (λ (m) (string->number (cadr m)))]
    [else #f]))

;; name -> valexpr（整数/浮点，或 alias 的符号）
(define constant-map (make-hasheqv))
(define (put-constant! name valexpr)
  (unless (hash-has-key? constant-map name)
    (hash-set! constant-map name valexpr)))

(define (enumerant->valexpr e ext-number)
  (define alias (attr e 'alias #f))
  (cond
    [alias (string->symbol alias)]
    [(attr e 'value) (parse-c-int (attr e 'value))]
    [(attr e 'bitpos) (arithmetic-shift 1 (string->number (attr e 'bitpos)))]
    [(attr e 'offset)
     (define off (string->number (attr e 'offset)))
     (define en (or (and (attr e 'extnumber) (string->number (attr e 'extnumber))) ext-number))
     (define v (+ 1000000000 (* (- en 1) 1000) off))
     (if (equal? (attr e 'dir #f) "-") (- v) v)]
    [else #f]))

(for ([blk enums-blocks])
  (for ([e (find-all-by-tag 'enum blk)])
    (define nm (attr e 'name))
    (when nm
      (define v (enumerant->valexpr e #f))
      (when v (put-constant! (string->symbol nm) v)))))
(for ([fn closure])
  (define f (feature-by-name fn))
  (when f
    (for ([e (find-all-by-tag 'enum f)])
      (define nm (attr e 'name))
      (when nm (define v (enumerant->valexpr e #f)) (when v (put-constant! (string->symbol nm) v))))))
;; 扩展常量（含 extension-relative offset/extnumber）
(for ([pair ext-enums])
  (define en (string->number (car pair)))
  (define ch (cdr pair))
  (define nm (attr ch 'name))
  (when nm
    (define alias (attr ch 'alias #f))
    (cond [alias (put-constant! (string->symbol nm) (string->symbol alias))]
          [else (define v (enumerant->valexpr ch en)) (when v (put-constant! (string->symbol nm) v))])))
(for ([nm (hash-keys types-hash)])
  (define ty (hash-ref types-hash nm))
  (when (eq? (cat-of ty) 'define)
    (define mm (regexp-match #px"#define\\s+\\S+\\s+([0-9]+)\\s*$" (xtext ty)))
    (when mm (put-constant! nm (string->number (cadr mm))))))

;; 常量按依赖（alias）排序后输出
(define (ordered-constants)
  (define emitted (make-hasheqv))
  (define out '())
  (define (literal? v) (not (symbol? v)))
  (for ([nm (sort (hash-keys constant-map) (λ (a b) (string<? (symbol->string a) (symbol->string b))))])
    (define v (hash-ref constant-map nm))
    (when (literal? v)
      (hash-set! emitted nm #t)
      (set! out (cons `(define ,nm ,v) out))))
  ;; 反复处理 alias，直到不再前进
  (let loop ()
    (define progressed #f)
    (for ([nm (sort (hash-keys constant-map) (λ (a b) (string<? (symbol->string a) (symbol->string b))))])
      (unless (hash-has-key? emitted nm)
        (define v (hash-ref constant-map nm))
        (when (and (symbol? v) (hash-has-key? emitted v))
          (hash-set! emitted nm #t)
          (set! out (cons `(define ,nm ,v) out))
          (set! progressed #t))))
    (when progressed (loop)))
  (reverse out))

;; ------------------------------------------------------------------
;; 5. 决定要生成哪些类型
(eprintf "feature closure: ~a\n" closure)
(eprintf "wanted commands=~a types=~a\n" (length wanted-cmds) (length wanted-types))

;; ------------------------------------------------------------------
;; 6. C 类型 -> Racket ctype
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
        "MTLTexture_id" '_pointer "MTLSharedEvent_id" '_pointer "id" '_pointer))

(define (base-c-type-name s)
  (define toks (filter (λ (t) (and (not (string=? t ""))
                                   (not (member t '("const" "struct" "union" "enum" "volatile")))))
                       (regexp-split #px"[\\s*]+" (string-trim s))))
  (if (null? toks) "void" (last toks)))

(define (category-of nm)
  (define ty (hash-ref types-hash nm #f))
  (and ty (cat-of ty)))

(define (ctype-of-type-name nm)
  (cond
    [(hash-has-key? base-ctype nm) (hash-ref base-ctype nm)]
    [(hash-has-key? basetype-map nm) (hash-ref basetype-map nm)]
    [(hash-has-key? platform-ctype nm) (hash-ref platform-ctype nm)]
    [(hash-has-key? types-hash (string->symbol nm))
     (case (category-of (string->symbol nm))
       [(struct union enum bitmask handle funcpointer) (string->symbol (format "_~a" nm))]
       [(basetype) (hash-ref basetype-map nm '_pointer)]
       [else '_pointer])]
    [else '_pointer]))

;; ------------------------------------------------------------------
;; 7. 成员解析
(define (member-name m)
  (let ([n (find-first-by-tag 'name m)]) (and n (xtext n))))
(define (members-of ty)
  (filter api-ok? (find-all-by-tag 'member ty)))
(define (member-type-text m)
  (let ([t (find-first-by-tag 'type m)]) (if t (xtext t) "")))
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
(define (array-size-expr m)
  (define e (find-first-by-tag 'enum m))
  (if e (string->symbol (xtext e))
      (let ([mm (regexp-match #px"\\[([0-9]+)\\]" (member-signature m))])
        (and mm (string->number (cadr mm))))))
(define (bitfield-member? m) (regexp-match? #px":\\s*[0-9]+" (member-text m)))
(define (member-base-name m) (base-c-type-name (member-type-text m)))

(define (member-ctype-expr m)
  (define base (member-base-name m))
  (cond
    [(pointer-member? m) '_pointer]
    [(array-member? m)
     (define sz (array-size-expr m))
     (if sz `(_array ,(ctype-of-type-name base) ,sz) '_pointer)]
    [else (ctype-of-type-name base)]))

;; by-value 依赖（原始类型名，用于拓扑排序/闭包）
(define (struct-dependencies nm)
  (define ty (hash-ref types-hash nm #f))
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
             [else '()])]))))

;; ------------------------------------------------------------------
;; 8. wanted 类型闭包 + 拓扑排序
(define (params-of c)
  (filter (λ (x) (and (xelem? x) (eq? (xtag x) 'param) (api-ok? x))) (xcontent c)))
(define (command-type-names c)
  (define eff (resolve-command c))
  (define acc (for/list ([p (params-of eff)]) (member-base-name p)))
  (define proto (find-first-by-tag 'proto eff))
  (if proto (cons (member-base-name proto) acc) acc))

(define wanted (make-hasheqv))
(for ([t wanted-types]) (when t (hash-set! wanted (string->symbol t) #t)))
(for ([c wanted-cmds])
  (define cmd (hash-ref commands-hash (string->symbol c) #f))
  (when cmd
    (for ([t (command-type-names cmd)])
      (when (hash-has-key? types-hash (string->symbol t))
        (hash-set! wanted (string->symbol t) #t)))))
(let loop ()
  (define before (hash-count wanted))
  (for ([nm (hash-keys wanted)])
    (for ([dep (struct-dependencies nm)])
      (when (hash-has-key? types-hash dep) (hash-set! wanted dep #t))))
  (when (> (hash-count wanted) before) (loop)))

(define (sym<? a b) (string<? (symbol->string a) (symbol->string b)))
(define wanted-list (sort (filter (λ (n) (hash-has-key? types-hash n)) (hash-keys wanted)) sym<?))

(define (topo-sort nodes deps-fn)
  (define node-set (make-hasheqv))
  (for ([n nodes]) (hash-set! node-set n #t))
  (define indeg (make-hasheqv))
  (define adj (make-hasheqv))
  (for ([n nodes]) (hash-set! indeg n 0) (hash-set! adj n '()))
  (for ([n nodes])
    (for ([d (deps-fn n)])
      (when (and (hash-ref node-set d #f) (not (eq? d n)))
        (hash-set! indeg n (add1 (hash-ref indeg n 0)))
        (hash-set! adj d (cons n (hash-ref adj d '()))))))
  (let loop ([q (filter (λ (n) (zero? (hash-ref indeg n))) nodes)] [out '()])
    (cond [(null? q) (append (reverse out) (filter (λ (n) (not (member n out))) nodes))]
          [else
           (define n (car q))
           (define newq (cdr q))
           (define nq (for/fold ([qq newq]) ([m (hash-ref adj n)])
                        (hash-set! indeg m (sub1 (hash-ref indeg m)))
                        (if (zero? (hash-ref indeg m)) (append qq (list m)) qq)))
           (loop nq (cons n out))])))
(define sorted-types (topo-sort wanted-list struct-dependencies))

;; ------------------------------------------------------------------
;; 9. 生成
(define (out-file name) (build-path out-dir name))
(define (emit forms path)
  (call-with-output-file path #:exists 'replace
    (λ (o) (for ([f forms]) (write f o) (newline o)))))

;; 9a. constants
(emit (ordered-constants) (out-file "constants.inc"))

;; 9b. types
(define type-forms '())
(define (handle->form nm)
  `(define ,(string->symbol (format "_~a" nm)) (_cpointer/null (quote ,(string->symbol (format "~a_T" nm))))))
(define (basetype->form nm)
  `(define ,(string->symbol (format "_~a" nm)) ,(hash-ref basetype-map (symbol->string nm) '_pointer)))
(define (bitmask->form nm ty)
  (define a (attr ty 'alias #f))
  (if a `(define ,(string->symbol (format "_~a" nm)) ,(string->symbol (format "_~a" a)))
      (let* ([raw (xtext ty)]
             [is64 (or (regexp-match? #px"VkFlags64" raw)
                       (let ([bv (attr ty 'bitvalues #f)])
                         (and bv (let ([blk (findf (λ (b) (equal? (attr b 'name) bv)) enums-blocks)])
                                   (and blk (equal? (attr blk 'bitwidth) "64"))))))])
        `(define ,(string->symbol (format "_~a" nm)) ,(if is64 '_uint64 '_uint32)))))
(define (enum->form nm ty)
  (define a (attr ty 'alias #f))
  (if a `(define ,(string->symbol (format "_~a" nm)) ,(string->symbol (format "_~a" a)))
      `(define ,(string->symbol (format "_~a" nm)) _int32)))
(define (funcpointer->form nm)
  `(define ,(string->symbol (format "_~a" nm)) _pointer))
(define (struct->form nm ty)
  (define members (filter (λ (m) (and (not (bitfield-member? m)) (member-name m)))
                          (members-of ty)))
  (define fields (for/list ([m members]) (list (string->symbol (member-name m)) (member-ctype-expr m))))
  (define fields* (if (null? fields) (list (list '_dummy '_uint8)) fields))
  `(define-cstruct ,(string->symbol (format "_~a" nm)) ,fields* #:malloc-mode 'zeroed-atomic-interior))
(define (union->form nm ty)
  (define members (filter member-name (members-of ty)))
  (define ctypes
    (for/list ([m members])
      (define base (member-base-name m))
      (cond
        [(pointer-member? m) '_pointer]
        [(array-member? m)
         (define sz (array-size-expr m))
         (if (integer? sz)
             `(_list-struct ,@(build-list sz (λ _ (ctype-of-type-name base))))
             `(_array ,(ctype-of-type-name base) ,sz))]
        [else (ctype-of-type-name base)])))
  (define ctypes* (if (null? ctypes) (list '_uint8) ctypes))
  `(define ,(string->symbol (format "_~a" nm)) (_union ,@ctypes*)))

(define (alias->form nm target)
  `(define ,(string->symbol (format "_~a" nm)) ,(string->symbol (format "_~a" target))))
(for ([nm sorted-types])
  (define ty (hash-ref types-hash nm))
  (define form
    ;; 带 alias 的类型统一生成 ctype 别名，避免 struct alias 被当成空结构体
    (if (attr ty 'alias #f)
        (alias->form nm (attr ty 'alias))
        (case (cat-of ty)
          [(handle) (handle->form nm)]
          [(basetype) (basetype->form nm)]
          [(bitmask) (bitmask->form nm ty)]
          [(enum) (enum->form nm ty)]
          [(struct) (struct->form nm ty)]
          [(union) (union->form nm ty)]
          [(funcpointer) (funcpointer->form nm)]
          [else #f])))
  (when form (set! type-forms (cons form type-forms))))
(emit (reverse type-forms) (out-file "types.inc"))

;; 9c. commands
(define skip-commands '("vkGetInstanceProcAddr" "vkGetDeviceProcAddr"))
(define (pointer-param? p) (regexp-match? #px"\\*" (member-signature p)))
(define (param-ctype p)
  (if (pointer-param? p) '_pointer (ctype-of-type-name (member-base-name p))))
(define (command-level c)
  (define params (params-of c))
  (define first (and (pair? params) (member-base-name (car params))))
  (case (and first (string->symbol first))
    [(VkInstance VkPhysicalDevice) 'instance]
    [(VkDevice VkQueue VkCommandBuffer VkExternalComputeQueueNV) 'device]
    [else 'global]))
;; 命令是否返回 VkResult（alias 命令按目标判定）
(define (command-result? c)
  (define eff (resolve-command c))
  (define proto (find-first-by-tag 'proto eff))
  (and proto (equal? (base-c-type-name (member-type-text proto)) "VkResult")))

;; safe 层的错误策略：VkResult 命令包一层 check-vk-result（由 gen/emit.rkt 生成）。
(define (command-form c)
  (define nm (command-name c))
  ;; alias 命令沿用目标命令的签名（proto/params/level）
  (define eff (resolve-command c))
  (define proto (find-first-by-tag 'proto eff))
  (define ret-base (base-c-type-name (member-type-text proto)))
  (define params (params-of eff))
  (define types (map param-ctype params))
  ;; 基础层只做绑定：VkResult 命令直接返回结果值，错误策略在 safe 层。
  (define fun
    (if (equal? ret-base "VkResult")
        `(_fun ,@types -> _VkResult)
        `(_fun ,@types -> ,(ctype-of-type-name ret-base))))
  `(define-vk ,(string->symbol nm) ,(command-level eff) ,(length params) ,fun))

(define command-forms
  (for/list ([nm wanted-cmds]
             #:when (and nm (not (member nm skip-commands))))
    (define c (hash-ref commands-hash (string->symbol nm) #f))
    (and c (command-form c))))
(emit (filter values command-forms) (out-file "commands.inc"))

;; --- 9d. 事实 IR：commands -> vk-command（emit 与 generated/api.rkt 共用）---
(define (handle-type-name? nm) (eq? (category-of (string->symbol nm)) 'handle))
(define (struct/union-type-name? nm)
  (memq (category-of (string->symbol nm)) '(struct union)))
(define (dispatch-param? p)
  (and (member (member-base-name p)
               '("VkInstance" "VkDevice" "VkPhysicalDevice" "VkQueue" "VkCommandBuffer"
                 "VkExternalComputeQueueNV"))
       #t))
(define (param-sym p) (string->symbol (member-name p)))
(define (count-param? p)
  (and (equal? (member-base-name p) "uint32_t")
       (regexp-match? #px"Count$" (member-name p))))
(define (find-count-field info-base)
  (define ty (hash-ref types-hash (string->symbol info-base) #f))
  (and ty
       (findf (λ (m) (regexp-match? #px"[Cc]ount$" (member-name m)))
              (members-of ty))))

(define (param-kind base)
  (case (category-of (string->symbol base))
    [(struct) 'struct] [(union) 'union] [(handle) 'handle]
    [(enum) 'enum] [(bitmask) 'bitmask] [(funcpointer) 'funcpointer]
    [(basetype) 'basetype]
    [else (cond [(member base '("void")) 'void]
                [(member base '("char" "signed char" "unsigned char")) 'char]
                [(hash-has-key? base-ctype base) 'scalar]
                [(hash-has-key? platform-ctype base) 'platform]
                [else 'unknown])]))

(define (param-const? p)
  (regexp-match? #px"\\bconst\\b" (member-signature p)))

(define (dispatch-base-of c)
  (define params (params-of (resolve-command c)))
  (and (pair? params) (dispatch-param? (car params)) (member-base-name (car params))))

;; vkAllocate* 的 count 字段名（在 info 结构体里，例如 commandBufferCount）
(define (allocate-count-field c)
  (define nm (command-name c))
  (and (regexp-match? #px"^vkAllocate" nm)
       (let* ([eff (resolve-command c)]
              [params (params-of eff)]
              [info (and (pair? params)
                         (findf (λ (p) (and (pointer-param? p)
                                            (struct/union-type-name? (member-base-name p))))
                                params))])
         (and info
              (let ([m (find-count-field (member-base-name info))])
                (and m (string->symbol (member-name m))))))))

;; struct/union 是否不含指针成员（递归）
(define flat-cache (make-hasheqv))
(define (flat-struct? base)
  (hash-ref flat-cache base
            (λ ()
              (define ty (hash-ref types-hash (string->symbol base) #f))
              (define res
                (and ty
                     (for/and ([m (members-of ty)])
                       (cond [(pointer-member? m) #f]
                             [(bitfield-member? m) #t]
                             [else
                              (define b (member-base-name m))
                              (or (not (hash-has-key? types-hash (string->symbol b)))
                                  (not (memq (category-of (string->symbol b)) '(struct union)))
                                  (flat-struct? b))]))))
              (hash-set! flat-cache base res)
              res)))

(define (api-param p)
  (define base (member-base-name p))
  (define ptr? (pointer-param? p))
  (define const? (param-const? p))
  (define kind (param-kind base))
  (define flat? (if (memq kind '(struct union)) (flat-struct? base) #t))
  (vk-param (param-sym p) base (ctype-of-type-name base) ptr? const? (count-param? p)
            kind (and ptr? (not const?)) flat?))

(define (api-command c)
  (define eff (resolve-command c))
  (vk-command (string->symbol (command-name c))
              (command-level eff)
              (command-result? c)
              (dispatch-base-of c)
              (map api-param (params-of eff))
              (allocate-count-field c)))

(define api-commands
  (filter values
          (for/list ([nm wanted-cmds]
                     #:when (and nm (not (member nm skip-commands))))
            (define c (hash-ref commands-hash (string->symbol nm) #f))
            (and c (api-command c)))))

;; --- 9e. 安全封装（流水线：classify -> per-shape emit）---
(define safe-forms (filter values (emit-safe-forms api-commands)))
(emit safe-forms (out-file "safe.inc"))

;; --- 9f. 生成 generated/api.rkt（IR 数据；结构体定义在 vulkan/api-facts.rkt）---
(define (command->datum c)
  `(vk-command ',(vk-command-name c) ',(vk-command-level c)
               ,(vk-command-result? c)
               ,(vk-command-dispatch c)
               (list ,@(map (λ (p)
                              `(vk-param ',(vk-param-name p) ,(vk-param-base p)
                                         ',(vk-param-ctype p)
                                         ,(vk-param-pointer? p) ,(vk-param-const? p)
                                         ,(vk-param-count? p) ',(vk-param-kind p)
                                         ,(vk-param-output? p) ,(vk-param-flat? p)))
                            (vk-command-params c)))
               ',(vk-command-count-field c)))

(define (emit-api commands path)
  (call-with-output-file path #:exists 'replace
    (λ (o)
      (display "#lang racket/base\n" o)
      (display ";; 自动生成（generate.rkt）：命令/参数事实，供组合层与测试消费。不要手改。\n" o)
      (display "(require vulkan/api-facts)\n" o)
      (display "(provide (all-from-out vulkan/api-facts) vk-command-facts)\n\n" o)
      (display "(define vk-command-facts\n  (list\n" o)
      (for ([c (in-list commands)])
        (display "    " o) (write (command->datum c) o) (newline o))
      (display "))\n" o))))
(emit-api api-commands (out-file "api.rkt"))

;; --- 9g. ABI 对照 C 程序（仅 core struct/union；本机头文件版本可能较 registry 旧，
;;        但 core 类型在 1.4.x 内稳定）---
(define (emit-abi-c path)
  (define names
    (for/list ([nm (in-list wanted-list)]
               #:when (and (member (symbol->string nm) feat-types)
                           (memq (category-of nm) '(struct union))))
      nm))
  (call-with-output-file path #:exists 'replace
    (λ (o)
      (display "#include <vulkan/vulkan.h>\n" o)
      (display "#include <stddef.h>\n" o)
      (display "#include <stdio.h>\n" o)
      (display "#define SZ(T) printf(\"S \" #T \" %zu %zu\\n\", sizeof(T), _Alignof(T))\n" o)
      (display "int main(void){\n" o)
      (for ([nm (in-list names)])
        (fprintf o "  SZ(~a);\n" nm))
      (display "  return 0;\n}\n" o)))
  (length names))

(define abi-count (emit-abi-c (out-file "abi_check.c")))

(eprintf "generated: constants=~a types=~a commands=~a safe=~a api=~a abi=~a -> ~a\n"
         (length (ordered-constants)) (length type-forms) (length command-forms)
         (length safe-forms) (length api-commands) abi-count out-dir)
