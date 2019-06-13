#|

This file is a part of NUMCL project.
Copyright (c) 2019 IBM Corporation
SPDX-License-Identifier: LGPL-3.0-or-later

NUMCL is free software: you can redistribute it and/or modify it under the terms
of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any
later version.

NUMCL is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
NUMCL.  If not, see <http://www.gnu.org/licenses/>.

|#

(in-package :numcl.impl)


;; dot(a, b[, out]) 	Dot product of two arrays.
;; linalg.multi_dot(arrays) 	Compute the dot product of two or more arrays in a single function call, while automatically selecting the fastest evaluation order.
;; vdot(a, b) 	Return the dot product of two vectors.
;; inner(a, b) 	Inner product of two arrays.
;; outer(a, b[, out]) 	Compute the outer product of two vectors.
;; matmul(a, b[, out]) 	Matrix product of two arrays.
;; tensordot(a, b[, axes]) 	Compute tensor dot product along specified axes for arrays >= 1-D.
;; einsum(subscripts, *operands[, out, dtype, …]) 	Evaluates the Einstein summation convention on the operands.
;; einsum_path(subscripts, *operands[, optimize]) 	Evaluates the lowest cost contraction order for an einsum expression by considering the creation of intermediate arrays.
;; linalg.matrix_power(a, n) 	Raise a square matrix to the (integer) power n.
;; kron(a, b) 	Kronecker product of two arrays.


;; not supporting ellipses for now.
;; docstring:
;; The symbol - has a special meaning that allows broadcasting,
;;  and can be used only once in each SPEC, similar to Numpy's ellipses (...).

(eval-when (:compile-toplevel :load-toplevel :execute ) (define-symbol-macro *einsum-documentation*
  "Performs Einstein's summation.
The SUBSCRIPT specification is significantly extended from that of Numpy
and can be seens as a full-brown DSL for array operations.

SUBSCRIPTS is a sequence of the form `(<SPEC>+ [-> <TRANSFORM>*] [-> [<SPEC>*])`.
The remaining arguments ARGS contain the input arrays and optionally the output arrays.

# SPEC

The first set of SPECs specifies the input subscripts,
and the second set of SPECs specifies the output subscripts.
Unlike Numpy, there can be multiple output subscripts:
It can performs multiple operations in the same loop, then return multiple values.
The symbol `->` can be a string and can belong to any package because it is compared by STRING=.

Each SPEC is an alphabetical string designator, such as a symbol IJK or a string \"IJK\",
where each alphabet is considered as an index. It signals a type-error when it contains any
non-alpha char. 
Note that a symbol NIL is interpreted as an empty list rather than N, I and L.

Alternatively, each SPEC can be a list that contains a list of symbols.
For example, `((i j) (j k) -> (i k))` and `(ij jk -> ik)` are equivalent.

When -> and the output SPECs are omitted, a single output is assumed and its spec is
a union of the input specs.
For example, `(ij jk)` is equivalent to `(ij jk -> ijk)`.
Note that `(ij jk)` and `(ij jk ->)` have the different meanings:
The latter sums up all elements.

# TRANSFORM

TRANSFORM is a list of element-wise operations.
The number of TRANSFORM should correspond to the number of outputs.
In each TRANSFORM, the elements in the input arrays can be referenced by $N, where N is a 1-indexed number.
Similarly the output array can be referred to by @N.

For example, `(ij ik -> (+ @1 (* $1 $2)) -> ik)` is equivalent to `(ij ik -> ik)` (a GEMM).

By default, TRANSFORM is `(+ @1 (* $1 ... $N))` for N inputs, which is equivalent to Einstein's summation.

# ARGS

The shape of each input array should unify against the corresponding input spec. For example,
with a spec IJI, the input array should be of rank 3 as well as
the 1st and the 3rd dimension of the input array should be the same.

The shape of each output array is determined by the corresponding output spec.
For example, if SUBSCRIPTS is `(ij jk -> ik)`, the output is an array of rank 2,
and the output shape has the same dimension as the first input in the first axis,
and the same dimension as the second input in the second axis.

If the output arrays are provided, their shapes and types are also checked against the
corresponding output spec.  The types should match the result of the numerical
operations on the elements of the input arrays.

The outputs are calculated in the following rule.

+ The output array types are calculated based on the TRANSFORM, and 
  the shapes are calcurated based on the SPEC and the input arrays.
+ The output arrays are allocated and initialized by zeros.
+ Einsum nests one loop for each index in the input specs.
  For example, `(ij jk -> ik)` results in a triple loop.
+ In the innermost loop, each array element is bound to `$1..$N` / `@1..@N`.
+ For each `@i`, `i`-th TRANSFORM is evaluated and assigned to `@i`.

+ If the same index appears multiple times in a single spec,
  they share the same value in each iteration.
  For example, `(ii -> i)` returns the diagonal elements of the matrix.

When TRANSFORMs are missing, it follows naturally from the default TRANSFORM values that

+ When an index used in the input spec is missing in the output spec,
  the axis is aggregated over the iteration by summation.
+ If the same index appears across the different input specs,
  the element values from the multiple input arrays are aggregated by multiplication.
  For example, `(ij jk -> ik)` will perform
  `(setf (aref a2 i k) (* (aref a0 i j) (aref a1 j k)))`
  when a0, a1 are the input arrays and a2 is the output array.

For example, (einsum '(ij jk) a b) is equivalent to:

```commonlisp
 (dotimes (i <max> <output>)
   (dotimes (j <max>)
     (dotimes (k <max>)
       (setf (aref <output> i j k) (* (aref a i j) (aref b j k))))))
```

# Performance

If SUBSCRIPTS is a constant, the compiler macro
builds an iterator function and make them inlined. Otherwise,
a new function is made in each call to einsum, resulting in a large bottleneck.
 (It could be memoized in the future.)

The nesting order of the loops are automatically decided based on the specs.
The order affects the memory access pattern and therefore the performance due to
the access locality. For example, when writing a GEMM which accesses three matrices
by `(setf (aref output i j) (* (aref a i k) (aref b k j)))`,
it is well known that ikj-loop is the fastest among other loops, e.g. ijk-loop.
EINSUM reorders the indices so that it maximizes the cache locality.
"))

(declaim (inline einsum))
(defun einsum (subscripts &rest args)
  #.*einsum-documentation*
  (apply (memoized-einsum-function (einsum-normalize-subscripts subscripts))
         args))

(function-cache:defcached memoized-einsum-function (normalized-subscripts)
  (compile nil (einsum-lambda normalized-subscripts)))

(define-compiler-macro einsum (&whole whole subscripts &rest args)
  (match subscripts
    ((list 'quote subscripts)
     `(funcall ,(einsum-lambda (einsum-normalize-subscripts subscripts))
               ,@args))
    (_
     whole)))

(defun safe-string= (a b)
  (and (typep a 'string-designator)
       (typep b 'string-designator)
       (string= a b)))

(defun einsum-normalize-subscripts (subscripts)
  "Normalizes the subscripts.
It first 'explodes' each spec into the list form.
It then generates the default output form, if missing.

It then translates the index symbols into a number
based on the order of appearance; This should make
the specs with the different symbols into the same form,
e.g. (ij jk -> ik) and (ik kj -> ij) results in the same normalized form.

It then computes the transforms, if missing.

The value returned is a plist of :inputs, :transforms, :outputs. 
"
  (flet ((explode (s)
           (typecase s
             (list (assert (every #'symbolp s)) s)
             (symbol (iter (for c in-vector (symbol-name s))
                           (assert (alpha-char-p c) nil
                                   'simple-type-error
                                   :format-control "Tried to make a spec from a non-alpha char ~a"
                                   :format-arguments (list c))
                           (collecting (intern (string c)))))))
         (indices (specs)
           (let (list)
             (iter (for spec in specs)
                   (iter (for index in spec)
                         (pushnew index list)))
             (nreverse list))))
    (ecase (count '-> subscripts :test #'safe-string=)
      (0
       (let* ((i-specs (mapcar #'explode subscripts))
              (indices  (indices i-specs))
              (o-specs (list (sort (copy-list indices) #'string<)))

              (alist (mapcar #'cons indices (iota (length indices))))
              (i-specs-num (sublis alist i-specs))
              (o-specs-num (sublis alist o-specs))
              
              (i-len (length i-specs))
              (o-len (length o-specs))
              (transforms
               (iter (for o from 1 to o-len)
                     (collect
                         `(+ ,(@ o) (* ,@(mapcar #'$ (iota i-len :start 1))))))))
         (list :inputs i-specs-num :transforms transforms :outputs o-specs-num)))
      (1
       (let* ((pos (position '-> subscripts :test #'safe-string=))
              (i-specs (mapcar #'explode (subseq subscripts 0 pos)))
              (o-specs (mapcar #'explode (or (subseq subscripts (1+ pos)) '(nil)))) ; default

              (indices (indices (append i-specs o-specs)))
              (alist (mapcar #'cons indices (iota (length indices))))
              (i-specs-num (sublis alist i-specs))
              (o-specs-num (sublis alist o-specs))

              (i-len (length i-specs))
              (o-len (length o-specs))
              (transforms
               (iter (for o from 1 to o-len)
                     (collecting
                      `(+ ,(@ o) (* ,@(mapcar #'$ (iota i-len :start 1))))))))
         (list :inputs i-specs-num :transforms transforms :outputs o-specs-num)))
      (2
       (let* ((pos (position '-> subscripts :test #'safe-string=))
              (i-specs (mapcar #'explode (subseq subscripts 0 pos)))
              (pos2 (position '-> subscripts :test #'safe-string= :start (1+ pos)))
              (transforms (subseq subscripts (1+ pos) pos2))
              (o-specs (mapcar #'explode (or (subseq subscripts (1+ pos2)) '(nil)))) ; default

              (indices (indices (append i-specs o-specs)))
              (alist (mapcar #'cons indices (iota (length indices))))
              (i-specs-num (sublis alist i-specs))
              (o-specs-num (sublis alist o-specs))

              (i-len (length i-specs))
              (o-len (length o-specs))
              (transforms
               (iter (for o from 1 to o-len)
                     (collecting
                      (or (nth (1- o) transforms)
                          `(+ ,(@ o) (* ,@(mapcar #'$ (iota i-len :start 1)))))))))
         (list :inputs i-specs-num :transforms transforms :outputs o-specs-num))))))

(defun ? (i) (in-current-package (symbolicate '? (princ-to-string i)))) ; index limit var
(defun $ (i) (in-current-package (symbolicate '$ (princ-to-string i)))) ; input element var
(defun @ (i) (in-current-package (symbolicate '@ (princ-to-string i)))) ; output element var
(defun & (i) (in-current-package (symbolicate '& (princ-to-string i)))) ; index iteration var
(defun map-specs (fn specs)
  (iter (for spec in specs)
        (collecting
         (iter (for index in spec)
               (collecting (funcall fn index))))))

(defun einsum-parse-subscripts (normalized-subscripts)
  (match normalized-subscripts
    ((plist :inputs     i-specs
            :transforms transforms
            :outputs    o-specs)
     (let* ((i-flat (remove-duplicates (flatten i-specs)))
            (o-flat (remove-duplicates (flatten o-specs)))
            (i-len (length i-specs))
            (o-len (length o-specs))
            (iter-specs
             (sort-locality (union i-flat o-flat) (append i-specs o-specs))))
       (assert (subsetp o-flat i-flat)
               nil
               "The output spec contains ~a which are not used in the input specs:~% input spec: ~a~%output spec: ~a"
               (set-difference o-flat i-flat) i-flat o-flat)
       (values
        i-specs
        (make-gensym-list i-len "I")
        (mapcar #'$ (iota i-len :start 1))

        o-specs
        (make-gensym-list o-len "O")
        (mapcar #'@ (iota o-len :start 1))

        iter-specs
        transforms)))))

(deftype index () `(integer 0 (,array-dimension-limit)))

(defun einsum-lambda (normalized-subscripts)
  "Parses SUBSCRIPTS (<SPEC>+ [-> <SPEC>*]) and returns a lambda form that iterates over it."
  (multiple-value-bind (i-specs i-vars i-evars
                        o-specs o-vars o-evars iter-specs transforms)
      (einsum-parse-subscripts normalized-subscripts)
    (with-gensyms (o-types)
      `(lambda (,@i-vars &optional ,@o-vars)
         (resolving
           ,@(iter (for var in i-vars)
                   (for spec in i-specs)
                   (collecting
                    `(declare (gtype (array * ,(mapcar #'? spec)) ,var))))
           (let* ((,o-types (einsum-output-types
                             ',transforms ',i-evars ',o-evars ,@i-vars))
                  ,@(iter (for o-var     in o-vars)
                          (for o-spec    in o-specs)
                          (for o from 0)
                          (collecting
                           `(,o-var
                             (or ,o-var
                                 (zeros (list ,@(mapcar #'? o-spec)) :type (nth ,o ,o-types)))))))
             (resolving
               ,@(iter (for var in o-vars)
                       (for spec in o-specs)
                       (collecting
                        `(declare (gtype (array * ,(mapcar #'? spec)) ,var))))
               (let ,(iter (for var in (append i-vars o-vars))
                           (collecting
                            ;; extract the base array
                            `(,var (array-displacement ,var))))
                 (specializing (,@i-vars ,@o-vars) ()
                   (declare (optimize (speed 2) (safety 0)))
                   (declare (type index ,@(mapcar #'? iter-specs)))
                   ,(einsum-body iter-specs i-specs o-specs i-vars o-vars i-evars o-evars transforms)))
               (values ,@(mapcar (lambda (var) `(ensure-singleton ,var))
                                 o-vars)))))))))

(defun einsum-output-types (transforms i-evars o-evars &rest arrays)
  "Try to simulate the range for 10 iterations; Stop if it converges.
Otherwise call float-substitution and simplify integers to fixnums."
  (iter (with i-types = (mapcar #'array-element-type arrays))
        (repeat 10)
        (for o-types
             initially (make-list (length o-evars)
                                  :initial-element
                                  '(integer 0 0))
             then      (iter (with alist =
                                   (mapcar #'cons
                                           (append i-evars o-evars)
                                           (append i-types o-types)))
                             (for transform in transforms)
                             (collecting
                              (interpret-type (sublis alist transform)))))
        ;; (print o-types)
        (for o-types-prev previous o-types)
        (until (equal o-types o-types-prev))
        (finally
         (if (equal o-types o-types-prev)
             (return o-types)
             (return (mapcar (lambda (type) (float-substitution type :int-result 'fixnum))
                             o-types))))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defstruct node
    (var (gensym "TMP"))
    (form nil)
    (ins nil)
    (outs nil)
    (used nil)
    (cleanup nil) ;; when true, the VAR should be written back to FORM by setf
    (declaration nil)
    (binder nil)
    (priority 0)))

(defvar *ssa-cache* (make-hash-table :test 'equal)
  "Alist for redundancy elimination, used during the compilation.
 Each key is a form, each value is a cons of tmporary variable and a boolean
 indicating whether it was bound.")

(defun cached-form (form)
  (assert (every #'symbolp (cdr form)))
  (node-var
   (ensure-gethash form *ssa-cache*
                   (make-node :form form
                              :binder 'let
                              :outs (remove-if-not #'symbolp (cdr form))))))

(declaim (inline +/64 */64))
(defun +/64 (a b) (logand #xffffffffffffffff (+ a b)))
(defun */64 (a b) (logand #xffffffffffffffff (* a b)))

(defun row-major-index-form (spec)
  (labels ((rec (spec)
             (ematch spec
               (nil
                0)
               ((list s1)
                ;; it is ok to let the first clause handle this,
                ;; but the expansion result is not esthetically pleasing
                (& s1))
               ((list* s1 rest)
                ;; most-positive-fixnum might also work, but I don't know
                ;; I also tried ub function (1type.lisp) but it did not get a good result
                (cached-form
                 `(+/64 ,(& s1)
                        ,(cached-form
                          `(*/64 ,(? s1)
                                 ,(rec rest)))))))))
    (rec (reverse spec))))

;; access:     (aref a i j k)
;; dimensions: (5 6 7)
;; row-major:  i*6*7 + j*7 + k : 3 multiplications
;;             ((i*6)+j)*7 + k : 2 multiplications

;; (print (row-major-index-form '(2 1 0)))

(defun einsum-body (iter-specs i-specs o-specs i-vars o-vars i-evars o-evars transforms)
  (let ((*ssa-cache* (make-hash-table :test 'equal)))
    (iter (for spec in i-specs)
          (for var  in i-vars)
          (for evar in i-evars)
          (for index = (row-major-index-form spec))
          (for form = `(aref ,var ,index))
          (setf (gethash form *ssa-cache*)
                (make-node :form form
                           :var  evar
                           :outs (list index)
                           :binder 'let
                           :declaration
                           `(derive ,var
                                    type
                                    (array-subtype-element-type type)
                                    ,evar))))

    (iter (for spec in o-specs)
          (for var  in o-vars)
          (for evar in o-evars)
          (for index = (row-major-index-form spec))
          (for form = `(aref ,var ,index))
          (setf (gethash form *ssa-cache*)
                (make-node :form form
                           :var  evar
                           :cleanup `((setf ,form ,evar))
                           :outs (list index)
                           :binder 'let
                           :declaration
                           `(derive ,var
                                    type
                                    (array-subtype-element-type type)
                                    ,evar))))

    (let ((nodes (make-hash-table)))
      ;; hashtable of var, node
      (iter (for (_ node) in-hashtable *ssa-cache*)
            (ematch node
              ((node var)
               (setf (gethash var nodes) node))))
      (iter (for spec in iter-specs)
            (for ? = (? spec))
            (for & = (& spec))
            (collect ? into ?s)
            (setf (gethash ? nodes)
                  (make-node :form ?
                             :var  ?
                             :priority 1))
            (setf (gethash & nodes)
                  (make-node :form ?
                             :var  &
                             :binder 'dotimes
                             :priority -1
                             ;; to respect the iter-specs ordering
                             :outs ?s)))
      
      ;; setting up in-edges
      (iter (for (var node) in-hashtable nodes)
            (ematch node
              ((node outs)
               (iter (for outvar in outs)
                     (ematch (gethash outvar nodes)
                       ((node :ins (place ins))
                        (pushnew var ins)))))))
      
      (einsum-body-iter (topological-sort nodes)
                        transforms))))

(defun topological-sort (nodes)
  "Topological sort based on Kahn (1962)"
  (let ((s     nil)
        (l     nil))

    ;; 1. find a list of "start nodes" which have no incoming edges and insert
    ;; them into a set S
    (iter (for (var node) in-hashtable nodes)
          (match node
            ((node :outs nil)
             (push node s))
            ;; else, do nothing
            ))

    (assert s)

    (iter (while s) 
          ;; pop dotimes binding first
          (setf s (sort s #'> :key #'node-priority))
          (for n = (pop s))
          (push n l)
          (ematch n
            ((node :var n-var ins)
             (iter (for m-var in ins)
                   (for m = (gethash m-var nodes))
                   (removef (node-outs m) n-var)
                   (when (null (node-outs m))
                     (push m s))))))
    
    (assert (iter (for (var node) in-hashtable nodes)
                  (match node
                    ((node outs)
                     (always (null outs)))))
            nil
            "graph has a cycle")
    (nreverse l)))

(defun einsum-body-iter (nodes transforms)
  "Consume one index in iter-specs and use it for dotimes."

  (labels ((rec (nodes)
             (ematch nodes
               ((list* (node var form :binder 'dotimes) rest)
                `(dotimes (,var ,form)
                   ,(rec rest)))
               ((list* (node :binder nil) rest)
                (rec rest))
               ((list* (node var form :binder 'let declaration cleanup) rest)
                `(let ((,var ,form))
                   ,@(when declaration `((declare ,declaration)))
                   ,(rec rest)
                   ,@cleanup))
               
               (nil
                
                (iter (for transform in transforms)
                      (for o from 1)
                      (for o-sym = (@ o))
                      (when (first-iteration-p)
                        (collecting 'progn))
                      (collecting
                       `(setf ,o-sym ,transform)))))))
    (rec nodes)))

(defun spec-depends-on (spec iter-specs)
  (intersection iter-specs spec))

(defun sort-locality (indices subscripts)
  (sort (copy-list indices)
        (lambda (index1 index2)
          (locality< index1 index2 subscripts))))

(defun locality< (index1 index2 subscripts)
  "Returns true when index1 is less local than index2; i.e. index2 is more local"
  (assert (not (eq index1 index2)))
  (flet ((score (index1 index2)
           ;; the number of ordering violations
           ;; for looping index1 first 
           (iter (for spec in subscripts)
                 (for pos1 = (position index1 spec))
                 (for pos2 = (position index2 spec))
                 (counting
                  ;; count the violation
                  (and pos1 pos2 (< pos2 pos1))))))
    (< (score index1 index2)
       (score index2 index1))))

;; (einsum '(ij jk -> ik) a b)             ; -> becomes an ijk loop
;; (einsum '(ik kj -> ij) a b)             ; -> becomes an ikj loop
