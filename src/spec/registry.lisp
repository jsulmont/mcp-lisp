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
           #:clear-specs))

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
(defvar *requirements* (make-hash-table :test #'equal)
  "Non-invariant requirements tracked for compliance matrices.")

;;; ---------------------------------------------------------------------------
;;; Known keywords for validation at macroexpand time
;;; ---------------------------------------------------------------------------

(defparameter +known-field-keys+ '(:required :default :unique :min :max :derived-from :immutable :nullable))
(defparameter +relation-types+ '(:has-many :has-one :belongs-to))

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
  (clrhash *helpers*)
  (clrhash *helper-sources*)
  (clrhash *valuesets*)
  (clrhash *requirements*)
  (setf *config* nil)
  (setf *current-config* nil)
  (clrhash *compiled-fn-cache*)
  (values))
