#lang racket/base
;; ============================================================
;; 极简 xexpr 读取工具（vk.xml 是普通 s 表达式，无需完整 XML 库）。
;; 纯函数，无状态；被 registry / ctype / constants 复用。
;; ============================================================

(require racket/list
         racket/string)

(provide xelem? xtag xattrs xcontent attr
         find-all-by-tag find-first-by-tag
         text-of xtext type-name cat-of api-ok?)

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
