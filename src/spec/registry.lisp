;;;; src/spec/registry.lisp
;;;;
;;;; Central registries for the behavioral specification DSL.

(defpackage #:mcp-lisp/src/spec/registry
  (:use #:cl)
  (:export #:*entities*
           #:*rules*
           #:*invariants*
           #:*generators*
           #:*generator-sources*
           #:*variants*
           #:*mixins*
           #:*compounds*
           #:*config*
           #:*current-config*
           #:*scenarios*
           #:*scenario-generators*
           #:*scenario-generator-sources*
           #:*scenario-negative-generators*
           #:*scenario-negative-generator-sources*
           #:*compiled-fn-cache*
           #:*helpers*
           #:*helper-sources*
           #:*valuesets*
           #:*requirements*
           #:+known-field-keys+
           #:+relation-types+
           #:clear-specs
           #:*dsl-docs*
           #:register-dsl-doc))

(in-package #:mcp-lisp/src/spec/registry)

;;; ---------------------------------------------------------------------------
;;; Registries
;;; ---------------------------------------------------------------------------

(defvar *entities* (make-hash-table :test #'equal))
(defvar *rules* (make-hash-table :test #'equal))
(defvar *invariants* (make-hash-table :test #'equal))
(defvar *generators* (make-hash-table :test #'equal))
(defvar *generator-sources* (make-hash-table :test #'equal))
(defvar *variants* (make-hash-table :test #'equal))
(defvar *config* nil
  "Config field specs — a list of (NAME TYPE &key ...) forms set by DEFCONFIG.")
(defvar *current-config* nil
  "Currently active config plist, bound dynamically during PBT.")
(defvar *scenarios* (make-hash-table :test #'equal))
(defvar *scenario-generators* (make-hash-table :test #'equal))
(defvar *scenario-generator-sources* (make-hash-table :test #'equal))
(defvar *scenario-negative-generators* (make-hash-table :test #'equal))
(defvar *scenario-negative-generator-sources* (make-hash-table :test #'equal))
(defvar *compiled-fn-cache* (make-hash-table :test #'equal))
(defvar *helpers* (make-hash-table :test #'equal))
(defvar *helper-sources* (make-hash-table :test #'equal))
(defvar *valuesets* (make-hash-table :test #'equal)
  "Named value sets for use in invariant checks via IN-SET.")
(defvar *mixins* (make-hash-table :test #'equal)
  "Mixin field sets for entity inheritance via supers.")
(defvar *compounds* (make-hash-table :test #'equal)
  "Compound (value object) type definitions for field expansion.")
(defvar *requirements* (make-hash-table :test #'equal)
  "Non-invariant requirements tracked for compliance matrices.")

;;; ---------------------------------------------------------------------------
;;; Known keywords for validation at macroexpand time
;;; ---------------------------------------------------------------------------

(defparameter +known-field-keys+ '(:required :default :unique :min :max :derived-from :immutable :nullable :present-when))
(defparameter +relation-types+ '(:has-many :has-one :belongs-to :many-to-many))

;;; ---------------------------------------------------------------------------
;;; DSL documentation registry
;;; ---------------------------------------------------------------------------

(defvar *dsl-docs* (make-hash-table :test #'equal)
  "Documentation entries for DSL forms. Keys are lowercase name strings.
Each value is a plist (:name :type :synopsis :example :options :section :order).")

(defun register-dsl-doc (name &key type synopsis example options section (order 0))
  "Register documentation for a DSL form.
TYPE is :macro, :function, or :variable.
SECTION groups entries in the generated reference."
  (setf (gethash (string-downcase (string name)) *dsl-docs*)
        (list :name (string-downcase (string name))
              :type type
              :synopsis synopsis
              :example example
              :options options
              :section section
              :order order)))

;;; ---------------------------------------------------------------------------
;;; clear-specs
;;; ---------------------------------------------------------------------------

(defun clear-specs ()
  "Reset all spec registries."
  (clrhash *entities*)
  (clrhash *rules*)
  (clrhash *invariants*)
  (clrhash *generators*)
  (clrhash *generator-sources*)
  (clrhash *variants*)
  (clrhash *scenarios*)
  (clrhash *scenario-generators*)
  (clrhash *scenario-generator-sources*)
  (clrhash *scenario-negative-generators*)
  (clrhash *scenario-negative-generator-sources*)
  (clrhash *mixins*)
  (clrhash *compounds*)
  (clrhash *helpers*)
  (clrhash *helper-sources*)
  (clrhash *valuesets*)
  (clrhash *requirements*)
  (setf *config* nil)
  (setf *current-config* nil)
  (clrhash *compiled-fn-cache*)
  (values))
