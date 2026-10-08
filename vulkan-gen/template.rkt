#lang racket/base
;; ============================================================
;; 模板：读文本模板文件 + `@@KEY@@` 字符串替换。
;;
;; 生成器/测试里的「模板程序」（目标模块骨架、ABI 对照 C 程序、探针程序）
;; 一律外置到 templates/ 目录，不再以字符串嵌进 Racket 代码。
;; ============================================================

(require racket/file
         racket/string
         racket/list)

(provide read-template
         fill-template)

(define (read-template path)
  (file->string path))

;; subs : (listof (cons string string))，键不带 @@。
(define (fill-template tmpl subs)
  (for/fold ([s tmpl]) ([kv (in-list subs)])
    (string-replace s (format "@@~a@@" (car kv)) (cdr kv))))
