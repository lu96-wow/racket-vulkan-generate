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
;; 替换后若仍有 @@KEY@@ 残留（缺 key / 拼写错），立即报错——不静默产出非法文件。
(define (fill-template tmpl subs)
  (define out
    (for/fold ([s tmpl]) ([kv (in-list subs)])
      (string-replace s (format "@@~a@@" (car kv)) (cdr kv))))
  (define leftover (regexp-match #px"@@[A-Za-z0-9_]+@@" out))
  (when leftover
    (error 'fill-template "template placeholder not substituted: ~a" (car leftover)))
  out)
