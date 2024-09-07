;;; -*- lexical-binding: t -*-
;;; js2r-highlights.el --- Highlight variable occurrences, free variables, etc.

;; Copyright (C) 2016-2024 Mihai Bazon <mihai.bazon@gmail.com>

;; Keywords: conveniences

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This is a minor mode that highlights certain things of interest and
;; allows you to easily move through them. The most useful is
;; `js2r-highlight-thing-at-point', which highlights occurrences of
;; the thing at point. You'd normally use it on variables, and it
;; selects all occurrences in the defining scope, but it also works on
;; constants (highlights occurrences in the whole buffer), or on
;; "this" or "super" keywords.
;;
;; There's also `js2r-highlight-free-vars' which selects free
;; variables in the enclosing function, and `js2r-highlight-exits'
;; which selects exit points from the current function ("return" or
;; "throw" nodes).
;;
;; While highlights mode is on, the following key bindings are
;; available:
;;
;;     C-<down> - `js2r-highlight-move-next'
;;     C-<up> - `js2r-highlight-move-prev'
;;     C-<return> - `js2r-highlight-rename'
;;     <escape> or C-g - `js2r-highlight-forgetit'
;;
;; `js2r-highlight-rename' will replace all highlighted regions with
;; something else (you'll specify in the minibuffer). When used on
;; variables it takes care to maintain code semantics, for example in
;; situations like this:
;;
;;     let { foo } = obj;
;;
;; With the cursor on "foo", `js2r-highlight-thing-at-point' will
;; select all occurrences of "foo" in the enclosing scope, and if you
;; use rename, it will convert to something like this, instead of
;; simply renaming:
;;
;;     let { foo: newName } = obj;
;;
;; such that newName will still be initialized to obj.foo, as in the
;; original code.
;;
;; I use the following key bindings to enter highlights mode:
;;
;;     (define-key js2-refactor-mode-map (kbd "M-?") 'js2r-highlight-thing-at-point)
;;     (define-key js2-refactor-mode-map (kbd "C-c C-f") 'js2r-highlight-free-vars)
;;     (define-key js2-refactor-mode-map (kbd "C-c C-x") 'js2r-highlight-exits)
;;
;; There is also an utility function suitable for expand-region, I
;; have the following in my `js2-mode-hook':
;;
;;     (setq er/try-expand-list '(js2r-highlight-extend-region))

;;; Code:

(defun js2r-highlight-thing-at-point (pos)
  "Highlight all occurrences of the thing at point.  Generally,
you would use this when the point is on a variable, and it will
highlight all usages of it in its defining scope.  You can also
use it on strings, numbers or literal regexps (highlights
occurrences in the whole buffer), or on keywords `this' and
`super' (highlights occurrences in the current function)."
  (interactive "d")
  (js2-reparse)
  (js2r-highlight-forgetit)
  (js2r--hl-things (or (js2r--hl-get-regions pos)
                       (js2r--hl-get-regions (- pos 1)))))

(defun js2r-highlight-free-vars (pos &optional undeclared?)
  "Highlights free variables in the function surrounding
point (all variables defined in an upper scope).  If a function
has no free variables, or if they are all globals, it can be
safely lifted to an upper scope.  By default undeclared variables
are not included (assumed to be globally defined somewhere else).
Pass a prefix argument if you need to include them (the optional
`undeclared?' argument)."
  (interactive "d\nP")
  (js2-reparse)
  (js2r-highlight-forgetit)
  (let ((data (js2r--hl-things (js2r--hl-get-free-vars-regions pos (not undeclared?))
                               :no-message t))
        (hash (make-hash-table :test 'equal)))
    (cl-loop
       for (name) in data
       for count = (or (gethash name hash) 0)
       do (puthash name (1+ count) hash))
    (message "%s"
             (with-temp-buffer
                 (insert (format "%d places: " (length data)))
               (cl-loop
                  for first = t then nil
                  for name being the hash-keys of hash using (hash-values count)
                  do (unless first (insert ", "))
                     (insert (format "%s × %d" name count)))
               (buffer-substring-no-properties (point-min) (point-max))))))

(defun js2r-highlight-exits (pos)
  "Highlights forced exit points from the function surrounding
point, that is, `return' and `throw' statements."
  (interactive "d")
  (js2-reparse)
  (js2r-highlight-forgetit)
  (js2r--hl-things (js2r--hl-get-exits-regions pos)))

(defun js2r-highlight-rename (pos new-name)
  "Replace the highlighted things with something else.  Currently
this only works if the mode was called with
`js2r-highlight-thing-at-point'."
  (interactive "d\nsReplace with: ")
  (let ((places (sort (js2r--hl-get-regions pos)
                      (lambda (a b)
                        (< (cdr (assq 'begin b))
                           (cdr (assq 'begin a)))))))
    (save-excursion
     (dolist (p places)
       (let ((begin (cdr (assq 'begin p)))
             (end (cdr (assq 'end p)))
             (node (cdr (assq 'node p))))
         (cond
           ((and (js2-name-node-p node)
                 (js2-object-prop-node-p (js2-node-parent node))
                 (eq node (js2-object-prop-node-left (js2-node-parent node)))
                 (eq node (js2-object-prop-node-right (js2-node-parent node))))
            (goto-char end)
            (insert ": " new-name))
           (t
            (delete-region begin end)
            (goto-char begin)
            (insert new-name)))))
     (message "%d occurrences renamed to %s" (length places) new-name))
    (js2r-highlight-forgetit)))

(defun js2r-highlight-forgetit ()
  "Exit the highlight minor mode."
  (interactive)
  (remove-overlays (point-min) (point-max) 'js2r-highlights t)
  (js2r--hl-mode 0))

(defun js2r-highlight-move-next ()
  "Move cursor to the next highlighted node."
  (interactive)
  (catch 'done
    (dolist (i (js2r--hl-get-overlays nil))
      (let ((x (overlay-start i)))
        (when (> x (point))
          (goto-char x)
          (throw 'done nil))))))

(defun js2r-highlight-move-prev ()
  "Move cursor to the previous highlighted node."
  (interactive)
  (catch 'done
    (dolist (i (js2r--hl-get-overlays t))
      (when (< (overlay-end i) (point))
        (goto-char (overlay-start i))
        (throw 'done nil)))))

(defun js2r-highlight-extend-region ()
  "Extend region to the current or upper AST node.  Function
suitable for `er/try-expand-list' (from expand-region), which
see."
  (interactive)
  (js2-reparse)
  (cond
    ((use-region-p)
     (cl-loop
        for node = (js2-node-at-point) then (js2-node-parent node)
        for beg = (point) then (js2-node-abs-pos node)
        for end = (mark) then (js2-node-abs-end node)
        until (or (< beg (point)) (> end (mark)))
        finally
           (goto-char beg)
           (push-mark end t t)))
    (t
     (let ((node (js2-node-at-point (point))))
       (goto-char (js2-node-abs-pos node))
       (push-mark (js2-node-abs-end node) t t)))))

(defun js2r--hl-get-var-regions ()
  (let* ((current-node (js2r--local-name-node-at-point))
         (len (js2-node-len current-node)))
    (mapcar (lambda (beg)
              `((begin . ,beg)
                (end . ,(+ beg len))
                (node . ,(js2-node-at-point beg))))
            (js2r--local-var-positions current-node t))))

(defun js2r--constant-node-value (node)
  (cond
    ((js2-number-node-p node) (js2-number-node-value node))
    ((js2-string-node-p node) (js2-string-node-value node))
    ((js2-regexp-node-p node) (js2-regexp-node-value node))
    (t (error "Not a constant node"))))

(defun js2r--hl-get-constant-regions (const)
  (let* ((regions (list))
         (type (js2-node-type const))
         (value (js2r--constant-node-value const)))
    (js2-visit-ast js2-mode-ast
                   (lambda (node end-p)
                     (unless end-p
                       (cond
                         ((and (= type (js2-node-type node))
                               (equal value (js2r--constant-node-value node)))
                          (push `((begin . ,(js2-node-abs-pos node))
                                  (end . ,(js2-node-abs-end node)))
                                regions))))
                     t))
    regions))

(defun js2r--hl-get-regions (pos)
  (let ((node (js2-node-at-point pos)))
    (cond
      ((js2-name-node-p node) (js2r--hl-get-var-regions))
      ((or (js2-string-node-p node)
           (js2-number-node-p node)
           (js2-regexp-node-p node))
       (js2r--hl-get-constant-regions node))
      ((js2-this-or-super-node-p node)
       (js2r--hl-get-this-regions node)))))

(defun js2r--hl-parent-function-this (node)
  (setq node (js2-node-parent node))
  (while (and node
              (or (not (js2-function-node-p node))
                  (eq 'FUNCTION_ARROW (js2-function-node-form node))))
    (setq node (js2-node-parent node)))
  (and (js2-function-node-p node) node))

(defun js2r--hl-get-this-regions (node)
  (let ((func (js2r--hl-parent-function-this node))
        (type (js2-node-type node))
        (regions (list)))
    (unless func
      (error "Not inside a function"))
    (js2-visit-ast func
                   (lambda (node end-p)
                     (cond
                       ((js2-function-node-p node)
                        (or (eq node func)
                            (eq (js2-function-node-form node) 'FUNCTION_ARROW)))
                       ((eq (js2-node-type node) type)
                        (push `((begin . ,(js2-node-abs-pos node))
                                (end . ,(js2-node-abs-end node)))
                              regions))
                       (t t))))
    regions))

(defun js2r--hl-get-free-vars-regions (pos undeclared?)
  (let* ((node (js2-node-at-point pos t))
         (func (js2-mode-find-enclosing-fn node))
         (regions (list)))
    (cl-flet ((is-free? (node)
                (cl-block is-free?      ; cl-flet bug?
                  (let* ((name (js2-name-node-name node))
                         (sym (if (symbolp name) name (intern name)))
                         (p (js2-node-parent node)))
                    (while p
                      (when (js2-scope-p p)
                        (when (cdr (assq sym (js2-scope-symbol-table p)))
                          (return-from is-free? nil)))
                      (when (eq p func)
                        (return-from is-free?
                          (or undeclared?
                              (not (null (js2-get-defining-scope func name))))))
                      (setf p (js2-node-parent p)))))))
      (js2-visit-ast
       func
       (lambda (node end-p)
         (unless end-p
           (when (and (js2r--local-name-node-p node)
                      (not (and (js2-function-node-p func)
                                (eq node (js2-function-node-name func))))
                      (is-free? node))
             (push `((begin . ,(js2-node-abs-pos node))
                     (end . ,(js2-node-abs-end node)))
                   regions)))
         t)))
    regions))

(defun js2r--hl-get-exits-regions (pos)
  (let* ((node (js2-node-at-point pos t))
         (func (js2-mode-find-parent-fn node))
         (regions (list)))
    (unless func
      (error "Not inside a function"))
    (js2-visit-ast
     func
     (lambda (node end-p)
       (cond
         ((js2-function-node-p node)
          (eq node func))
         ((not end-p)
          (when (or (js2-throw-node-p node)
                    (js2-return-node-p node))
            (push `((begin . ,(js2-node-abs-pos node))
                    (end . ,(js2-node-abs-end node)))
                  regions))
          t))))
    regions))

(defun js2r--hl-get-overlays (rev)
  (sort (remove-if-not (lambda (ov)
                         (overlay-get ov 'js2r-highlights))
                       (overlays-in (point-min) (point-max)))
        (if rev
            (lambda (a b)
              (> (overlay-start a) (overlay-start b)))
            (lambda (a b)
              (< (overlay-start a) (overlay-start b))))))

(defun js2r--hl-things (things &rest options)
  (let ((line-only (plist-get options :line-only))
        (no-message (plist-get options :no-message))
        (things (sort things
                      (lambda (a b)
                        (< (cdr (assq 'begin a))
                           (cdr (assq 'begin b)))))))
    (cond
      (things (let ((data (cl-loop
                             for ref in things
                             for beg = (cdr (assq 'begin ref))
                             for end = (if line-only
                                           (save-excursion
                                            (goto-char beg)
                                            (end-of-line)
                                            (point))
                                           (cdr (assq 'end ref)))
                             do (let ((ovl (make-overlay beg end)))
                                  (overlay-put ovl 'face 'highlight)
                                  (overlay-put ovl 'evaporate t)
                                  (overlay-put ovl 'js2r-highlights t))
                             collect (list (buffer-substring-no-properties beg end) beg end))))
                (unless no-message
                  (message "%d places highlighted" (length things)))
                (js2r--hl-mode 1)
                data))
      (t
       (unless no-message
         (message "No places found"))))))

(define-minor-mode js2r--hl-mode
  "Internal mode used by `js2r-highlights'"
  nil
  "/•"
  `(
    (,(kbd "C-<down>") . js2r-highlight-move-next)
    (,(kbd "C-<up>") . js2r-highlight-move-prev)
    (,(kbd "C-<return>") . js2r-highlight-rename)
    (,(kbd "<escape>") . js2r-highlight-forgetit)
    (,(kbd "C-g") . js2r-highlight-forgetit)
    ))

(provide 'js2r-highlights)
