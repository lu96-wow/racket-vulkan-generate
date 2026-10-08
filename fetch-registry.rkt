#lang racket/base
;; ============================================================
;; 按版本拉取 Vulkan 注册表（vk.xml），标准化资源获取。
;;
;;   racket fetch-registry.rkt 1.4.363          # -> registry/vk-1.4.363.xml
;;   racket fetch-registry.rkt main              # -> registry/vk-main.xml
;;   racket fetch-registry.rkt --check registry/vk-1.4.363.xml 1.4.363
;;
;; 默认来源（Khronos Vulkan-Docs 的 git ref）：
;;   https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/<ref>/xml/vk.xml
;;   version X.Y.Z -> ref=vX.Y.Z；main -> main；其他字符串按 git ref 原样。
;;
;; 选项：
;;   --out <dir>     输出目录（默认 <仓库>/registry）
;;   --url <模板>   覆盖来源（{ref} 占位；支持 http(s):// 或本地路径）
;;   --force         覆盖已存在文件
;;   --check <file>  只校验已有文件，不下载
;;
;; 校验：可被 XML 解析且根元素为 <registry>；对 X.Y.Z 还要求
;;   VK_HEADER_VERSION == Z 且 VK_HEADER_VERSION_COMPLETE 的主/次版本匹配。
;; ============================================================

(require racket/file
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         net/url
         xml)

(provide fetch-registry!
         registry-version?)

(define-runtime-path here-raw ".")
(define here (simplify-path here-raw))
(define default-out-dir (build-path here "registry"))
(define default-url-template
  "https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/{ref}/xml/vk.xml")

;; X.Y.Z（Vulkan 版本）还是任意 git ref（如 main、v1.4.363）
(define (registry-version? v)
  (and (regexp-match? #px"^[0-9]+\\.[0-9]+\\.[0-9]+$" v) #t))
(define (version->ref v)
  (if (registry-version? v) (string-append "v" v) v))
(define (version->filename v)
  (string-append "vk-" v ".xml"))
(define (filename->version f)
  (define m (regexp-match #px"^vk-(.+)\\.xml$" (path->string (file-name-from-path f))))
  (and m (cadr m)))

;; http(s)://... 或本地路径
(define (read-source url-or-path)
  (define u (if (regexp-match? #px"^[a-zA-Z][a-zA-Z0-9+.-]*://" url-or-path)
                (string->url url-or-path)
                (path->url (path->complete-path url-or-path))))
  (define p (get-pure-port u))
  (begin0 (port->bytes p) (close-input-port p)))

(define (download url [tries 3])
  (let loop ([i 0])
    (with-handlers ([(λ (e) (and (exn? e) (< i tries)))
                     (λ (e) (eprintf "fetch 重试 ~a/~a: ~a\n" (add1 i) tries (exn-message e)) (loop (add1 i)))])
      (read-source url))))

(define (validate bytes version)
  ;; 1) 能解析 + 根元素
  (define doc
    (with-handlers ([exn:fail? (λ (e) (error 'fetch-registry "XML 解析失败：~a" (exn-message e)))])
      (read-xml (open-input-bytes bytes))))
  (define root (document-element doc))
  (unless (eq? (element-name root) 'registry)
    (error 'fetch-registry "根元素不是 <registry>（得到 ~a）" (element-name root)))
  ;; 2) 版本自检（取第一个 VK_HEADER_VERSION，即 Vulkan 主线，非 Vulkan SC）
  (define text (bytes->string/utf-8 bytes))
  (define hm (regexp-match #px"VK_HEADER_VERSION</name>\\s+([0-9]+)" text))
  (define header (and hm (string->number (cadr hm))))
  (define cm (regexp-match #px"VK_HEADER_VERSION_COMPLETE</name>[^()]*\\(([^)]*)\\)" text))
  (define complete (and cm (string-trim (cadr cm))))
  (when (registry-version? version)
    (define m (regexp-match #px"^([0-9]+)\\.([0-9]+)\\.([0-9]+)$" version))
    (define want-major (string->number (list-ref m 1)))
    (define want-minor (string->number (list-ref m 2)))
    (define want-patch (string->number (list-ref m 3)))
    (unless (equal? header want-patch)
      (error 'fetch-registry "版本不符：请求 ~a，但 XML VK_HEADER_VERSION=~a" version header))
    (define args (and complete (map string-trim (string-split complete ","))))
    (define cmajor (and args (>= (length args) 3) (string->number (list-ref args 1))))
    (define cminor (and args (>= (length args) 3) (string->number (list-ref args 2))))
    (unless (and cmajor cminor (= cmajor want-major) (= cminor want-minor))
      (error 'fetch-registry "VK_HEADER_VERSION_COMPLETE=(~a) 与请求 ~a 不符" complete version)))
  (values header complete))

(define (write-atomic! bytes path)
  (define tmp (string-append (path->string path) ".tmp"))
  (call-with-output-file tmp #:exists 'replace (λ (o) (write-bytes bytes o)))
  (rename-file-or-directory tmp path #t))

(define (fetch-registry! version
                         #:out [out-dir default-out-dir]
                         #:url [url-template default-url-template]
                         #:force? [force? #f])
  (unless (and version (string? version) (positive? (string-length version)))
    (error 'fetch-registry "缺少版本（如 1.4.363 或 main）"))
  (define out (build-path out-dir (version->filename version)))
  (when (and (file-exists? out) (not force?))
    (error 'fetch-registry "已存在 ~a（用 --force 覆盖）" out))
  (define url (string-replace url-template "{ref}" (version->ref version)))
  (eprintf "fetch: ~a\n" url)
  (define bytes (download url))
  (define-values (header complete) (validate bytes version))
  (make-directory* out-dir)
  (write-atomic! bytes out)
  (printf "saved: ~a\n  VK_HEADER_VERSION=~a  VK_HEADER_VERSION_COMPLETE=(~a)  ~a bytes\n"
          out header complete (bytes-length bytes))
  out)

(define (check-registry! path version)
  (define v (or version (filename->version path) "main"))
  (define-values (header complete) (validate (file->bytes path) v))
  (printf "ok: ~a\n  version=~a  VK_HEADER_VERSION=~a  VK_HEADER_VERSION_COMPLETE=(~a)\n"
          path v header complete))

(module+ main
  (define (usage)
    (displayln "用法: racket fetch-registry.rkt <version|main> [--out DIR] [--url TEMPLATE] [--force]")
    (displayln "      racket fetch-registry.rkt --check <file> [version]")
    (displayln "  version 如 1.4.363（tag v1.4.363）或 main；来源默认 KhronosGroup/Vulkan-Docs。"))
  (define (need-value! rest flag)
    (when (null? rest) (error 'fetch-registry "~a 缺少参数" flag))
    (car rest))
  (let loop ([args (vector->list (current-command-line-arguments))]
             [version #f] [out-dir #f] [url #f] [force? #f] [check #f])
    (cond
      [(null? args)
       (cond
         [check (check-registry! check version)]
         [else (fetch-registry! (or version "main")
                                #:out (or out-dir default-out-dir)
                                #:url (or url default-url-template)
                                #:force? force?)])]
      [(member (car args) '("--help" "-h")) (usage)]
      [(equal? (car args) "--force") (loop (cdr args) version out-dir url #t check)]
      [(equal? (car args) "--out")   (loop (cddr args) version (need-value! (cdr args) "--out") url force? check)]
      [(equal? (car args) "--url")   (loop (cddr args) version out-dir (need-value! (cdr args) "--url") force? check)]
      [(equal? (car args) "--check") (loop (cddr args) version out-dir url force? (need-value! (cdr args) "--check"))]
      [(string-prefix? (car args) "--") (error 'fetch-registry "未知选项 ~a" (car args))]
      [else (loop (cdr args) (car args) out-dir url force? check)])))
