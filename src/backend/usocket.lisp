(in-package :cl-user)
(defpackage dexador.backend.usocket
  (:nicknames :dex.usocket)
  (:use :cl
        :dexador.encoding
        :dexador.util)
  (:import-from :dexador.connection-cache
                :steal-connection
                :push-connection)
  (:import-from :dexador.error
                :http-request-failed
                :http-request-not-found)
  (:import-from :usocket
                :socket-connect
                :socket-stream)
  (:import-from :fast-http
                :make-http-response
                :make-parser
                :http-status
                :http-headers)
  (:import-from :fast-io
                :make-output-buffer
                :finish-output-buffer
                :with-fast-output
                :fast-write-sequence
                :fast-write-byte)
  (:import-from :trivial-mimes
                :mime)
  (:import-from :cl-cookie
                :merge-cookies
                :parse-set-cookie-header
                :cookie-jar-host-cookies
                :write-cookie-header)
  (:import-from :quri
                :uri-p
                :uri-host
                :uri-port
                :uri-path
                :uri-authority
                :uri-scheme
                :url-encode-params
                :merge-uris)
  (:import-from :chipz
                :decompress
                :make-dstate)
  (:import-from :cl-base64
                :string-to-base64-string)
  #-dexador-no-ssl
  (:import-from :cl+ssl
                :make-ssl-client-stream)
  (:import-from :alexandria
                :copy-stream
                :if-let
                :when-let
                :ensure-list)
  (:export :request

           ;; Restarts
           :retry-request
           :ignore-and-continue))
(in-package :dexador.backend.usocket)

(defun-speedy read-until-crlf (stream)
  (with-fast-output (buf)
    (tagbody
     read-cr
       (loop for byte of-type (or (unsigned-byte 8) null) = (read-byte stream nil nil)
             if byte
               do (fast-write-byte byte buf)
             else
               do (go eof)
             until (= byte (char-code #\Return)))

     read-lf
       (let ((next-byte (read-byte stream nil nil)))
         (declare (type (or (unsigned-byte 8) null) next-byte))
         (cond
           ((null next-byte)
            (go eof))
           ((= next-byte (char-code #\Newline))
            (fast-write-byte next-byte buf))
           ((= next-byte (char-code #\Return))
            (fast-write-byte next-byte buf)
            (go read-lf))
           (T
            (fast-write-byte next-byte buf)
            (go read-cr))))
     eof)))

(defun read-response (stream has-body collect-headers)
  (let* ((http (make-http-response))
         (body-data (make-output-buffer))
         (headers-data (and collect-headers
                            (make-output-buffer)))
         (header-finished-p nil)
         (finishedp nil)
         (content-length nil)
         (parser (make-parser http
                              :header-callback
                              (lambda (headers)
                                (setq header-finished-p t
                                      content-length (gethash "content-length" headers))
                                (unless (and has-body
                                             (or content-length
                                                 (gethash "transfer-encoding" headers)))
                                  (setq finishedp t)))
                              :body-callback
                              (lambda (data start end)
                                (fast-write-sequence data body-data start end))
                              :finish-callback
                              (lambda ()
                                (setq finishedp t)))))
    (loop for buf of-type octets = (if (and header-finished-p
                                            content-length)
                                       (let ((buf (make-array content-length :element-type '(unsigned-byte 8))))
                                         (read-sequence buf stream)
                                         buf)
                                       (read-until-crlf stream))
          do (when (and collect-headers
                        (not header-finished-p))
               (fast-write-sequence buf headers-data))
             (funcall parser buf)
          until (or finishedp
                    (zerop (length buf))))
    (values http
            (finish-output-buffer body-data)
            (and collect-headers
                 (finish-output-buffer headers-data)))))

(defun print-verbose-data (direction &rest data)
  (flet ((boundary-line ()
           (let ((char (ecase direction
                         (:incoming #\<)
                         (:outgoing #\>))))
             (fresh-line)
             (dotimes (i 50)
               (write-char char))
             (fresh-line))))
    (boundary-line)
    (dolist (d data)
      (map nil (lambda (byte)
                 (princ (code-char byte)))
           d))
    (boundary-line)))

(defun decompress-body (content-encoding body)
  (unless content-encoding
    (return-from decompress-body body))

  (cond
    ((string= content-encoding "gzip")
     (chipz:decompress nil (chipz:make-dstate :gzip) body))
    ((string= content-encoding "deflate")
     (chipz:decompress nil (chipz:make-dstate :deflate) body))
    (T body)))

(defun decode-body (content-type body)
  (let ((charset (and content-type
                      (detect-charset content-type))))
    (if charset
        (handler-case
            (babel:octets-to-string body :encoding charset)
          (error (e)
            (warn (format nil "Failed to decode the body to ~S due to the following error (falling back to binary):~%  ~A"
                          charset
                          e))
            (return-from decode-body body)))
        body)))

(defun content-disposition (key val)
  (format nil "Content-Disposition: form-data; name=\"~A\"~:[~;~:*; filename=\"~A\"~]~C~C"
          key
          (and (pathnamep val)
               (file-namestring val))
          #\Return #\Newline))

(defun-speedy multipart-content-length (content boundary)
  (declare (type simple-string boundary))
  (let ((boundary-length (length boundary)))
    (+ (loop for (key . val) in content
             sum (+ 2 boundary-length 2
                    (length (the simple-string (content-disposition key val)))
                    (if (pathnamep val)
                        (+ #.(length "Content-Type: ") (length (the simple-string (mimes:mime val))) 2)
                        0)
                    2
                    (typecase val
                      (pathname (with-open-file (in val)
                                  (file-length in)))
                      (string (length (the octets (babel:string-to-octets val))))
                      (symbol (length (the octets (babel:string-to-octets (princ-to-string val)))))
                      (otherwise (length (princ-to-string val))))
                    2))
       2 boundary-length 2 2)))

(defun write-multipart-content (content boundary stream)
  (let ((boundary (ascii-string-to-octets boundary)))
    (labels ((boundary-line (&optional endp)
               (write-sequence #.(ascii-string-to-octets "--") stream)
               (write-sequence boundary stream)
               (when endp
                 (write-sequence #.(ascii-string-to-octets "--") stream))
               (crlf))
             (crlf () (write-sequence +crlf+ stream)))
      (loop for (key . val) in content
            do (boundary-line)
               (write-sequence (ascii-string-to-octets (content-disposition key val)) stream)
               (when (pathnamep val)
                 (write-sequence
                  (ascii-string-to-octets
                   (format nil "Content-Type: ~A~C~C"
                           (mimes:mime val)
                           #\Return #\Newline))
                  stream))
               (crlf)
               (typecase val
                 (pathname (let ((buf (make-array 1024 :element-type '(unsigned-byte 8))))
                             (with-open-file (in val :element-type '(unsigned-byte 8))
                               (loop for n of-type fixnum = (read-sequence buf in)
                                     until (zerop n)
                                     do (write-sequence buf stream :end n)))))
                 (string (write-sequence (babel:string-to-octets val) stream))
                 (otherwise (write-sequence (babel:string-to-octets (princ-to-string val)) stream)))
               (crlf)
            finally
               (boundary-line t)))))

(defmacro http-request-failed-with-restarts (status &key body headers uri)
  `(restart-case
       (http-request-failed ,status
                            :body ,body
                            :headers ,headers
                            :uri ,uri)
     (retry-request ()
       :report "Retry the same request."
       (go retry))
     (ignore-and-continue ()
       :report "Ignore the error and continue.")))

(defun build-cookie-headers (uri cookie-jar)
  (with-header-output (buffer)
    (let ((cookies (cookie-jar-host-cookies cookie-jar (uri-host uri) (or (uri-path uri) "/")
                                            :securep (string= (uri-scheme uri) "https"))))
      (when cookies
        (fast-write-sequence #.(ascii-string-to-octets "Cookie: ") buffer)
        (fast-write-sequence
         (ascii-string-to-octets (write-cookie-header cookies))
         buffer)
        (fast-write-sequence +crlf+ buffer)))))

(defun-careful request (uri &rest args
                            &key (method :get) (version 1.1)
                            content headers
                            basic-auth
                            cookie-jar
                            (timeout *default-timeout*) (keep-alive t) (use-connection-pool t)
                            (max-redirects 5)
                            ssl-key-file ssl-cert-file ssl-key-password
                            stream verbose
                            force-binary)
  (declare (ignorable ssl-key-file ssl-cert-file ssl-key-password)
           (type float version))
  (flet ((make-new-connection (uri)
           (let ((stream
                   (usocket:socket-stream
                    (usocket:socket-connect (uri-host uri)
                                            (uri-port uri)
                                            :timeout timeout
                                            :element-type '(unsigned-byte 8)))))
             (if (string= (uri-scheme uri) "https")
                 #+dexador-no-ssl
                 (error "SSL not supported. Remove :dexador-no-ssl from *features* to enable SSL.")
                 #-dexador-no-ssl
                 (cl+ssl:make-ssl-client-stream stream
                                                :certificate ssl-cert-file
                                                :key ssl-key-file
                                                :password ssl-key-password)
                 stream)))
         (finalize-connection (stream connection-header uri)
           (if (and keep-alive
                    (or (and (= version 1.0)
                             (equalp connection-header "keep-alive"))
                        (not (equalp connection-header "close"))))
               (push-connection (uri-authority uri) stream)
               (ignore-errors (close stream)))))
    (let* ((uri (if (quri:uri-p uri)
                    uri
                    (quri:uri uri)))
           (multipart-p (and (consp content)
                             (find-if #'pathnamep content :key #'cdr)))
           (form-urlencoded-p (and (consp content)
                                   (not multipart-p)))
           (boundary (and multipart-p
                          (make-random-string 12)))
           (content (if form-urlencoded-p
                        (quri:url-encode-params content)
                        content))
           (stream (or stream
                       (and use-connection-pool
                            (steal-connection (uri-authority uri)))))
           (reusing-stream-p (not (null stream)))
           (stream (or stream
                       (make-new-connection uri)))
           (first-line-data
             (with-fast-output (buffer)
               (write-first-line method uri version buffer)))
           (headers-data
             (flet ((write-header* (name value)
                      (let ((header (assoc name headers :test #'string-equal)))
                        (if header
                            (when (cdr header)
                              (write-header name (cdr header)))
                            (write-header name value)))))
               (with-header-output (buffer)
                 (write-header* :user-agent #.*default-user-agent*)
                 (write-header* :host (uri-authority uri))
                 (write-header* :accept "*/*")
                 (when (and keep-alive
                            (= version 1.0))
                   (write-header* :connection "keep-alive"))
                 (when basic-auth
                   (write-header* :authorization
                                  (format nil "Basic ~A"
                                          (string-to-base64-string
                                           (format nil "~A:~A"
                                                   (car basic-auth)
                                                   (cdr basic-auth))))))
                 (cond
                   (multipart-p
                    (write-header* :content-type (format nil "multipart/form-data; boundary=~A" boundary))
                    (write-header* :content-length
                                   (multipart-content-length content boundary)))
                   (form-urlencoded-p
                    (write-header* :content-type "application/x-www-form-urlencoded")
                    (write-header* :content-length (length content)))
                   (t
                    (etypecase content
                      (null)
                      (string
                       (write-header* :content-type "text/plain")
                       (write-header* :content-length (length (babel:string-to-octets content))))
                      (pathname
                       (write-header* :content-type (mimes:mime content))
                       (if-let ((content-length (assoc :content-length headers :test #'string-equal)))
                         (write-header :content-length (cdr content-length))
                         (with-open-file (in content)
                           (write-header :content-length (file-length in))))))))

                 ;; Custom headers
                 (loop for (name . value) in headers
                       unless (member name '(:user-agent :host :accept
                                             :connection
                                             :content-type :content-length) :test #'string-equal)
                         do (write-header name value)))))
           (cookie-headers (and cookie-jar
                                (build-cookie-headers uri cookie-jar))))
      (macrolet ((with-retrying (&body body)
                   `(if reusing-stream-p
                        (handler-bind ((error
                                         (lambda (e)
                                           (declare (ignore e))
                                           (when reusing-stream-p
                                             (setf use-connection-pool nil
                                                   reusing-stream-p nil
                                                   stream (make-new-connection uri))
                                             (go retry)))))
                          ,@body)
                        (progn ,@body))))
        (tagbody
         retry
           (write-sequence first-line-data stream)
           (write-sequence headers-data stream)
           (when cookie-headers
             (write-sequence cookie-headers stream))
           (write-sequence +crlf+ stream)
           (with-retrying (force-output stream))

           ;; Sending the content
           (when content
             (etypecase content
               (string (write-sequence (babel:string-to-octets content) stream))
               (pathname (with-open-file (in content :element-type '(unsigned-byte 8))
                           (copy-stream in stream)))
               (cons
                (write-multipart-content content boundary stream)))
             (with-retrying (force-output stream)))

         start-reading
           (multiple-value-bind (http body response-headers-data)
               (with-retrying
                 (read-response stream (not (eq method :head)) verbose))
             (let ((status (http-status http))
                   (response-headers (http-headers http)))
               (when (= status 0)
                 (unless reusing-stream-p
                   ;; There's nothing we can do.
                   (http-request-failed-with-restarts status
                                                      :body body
                                                      :headers headers
                                                      :uri uri))
                 (setf use-connection-pool nil
                       reusing-stream-p nil
                       stream (make-new-connection uri))
                 (go retry))
               (when verbose
                 (print-verbose-data :outgoing first-line-data headers-data cookie-headers +crlf+)
                 (print-verbose-data :incoming response-headers-data))
               (when cookie-jar
                 (when-let (set-cookies (append (gethash "set-cookie" response-headers)
                                                (ensure-list (gethash "set-cookie2" response-headers))))
                   (merge-cookies cookie-jar
                                  (remove nil (mapcar (lambda (cookie)
                                                        (declare (type string cookie))
                                                        (unless (= (length cookie) 0)
                                                          (parse-set-cookie-header cookie
                                                                                   (uri-host uri)
                                                                                   (uri-path uri))))
                                                      set-cookies)))))
               (when (and (member status '(301 302 303 307) :test #'=)
                          (member method '(:get :head) :test #'eq)
                          (gethash "location" response-headers))
                 (let ((location-uri (quri:uri (gethash "location" response-headers))))
                   (if (or (null (uri-host location-uri))
                           (and (string= (uri-host location-uri)
                                         (uri-host uri))
                                (eql (uri-port location-uri)
                                     (uri-port uri))))
                       (progn
                         (unless (= 0 max-redirects)
                           (setq uri (merge-uris location-uri uri))
                           (setq first-line-data
                                 (with-fast-output (buffer)
                                   (write-first-line method uri version buffer)))
                           (when cookie-jar
                             ;; Rebuild cookie-headers.
                             (setq cookie-headers (build-cookie-headers uri cookie-jar)))
                           (decf max-redirects)
                           (if (equalp (gethash "connection" response-headers) "close")
                               (setq use-connection-pool nil
                                     reusing-stream-p nil
                                     stream (make-new-connection uri))
                               (setq reusing-stream-p t))
                           (go retry)))
                       (progn
                         (finalize-connection stream (gethash "connection" response-headers) uri)
                         (setf (getf args :headers)
                               (nconc `((:host . ,(uri-host location-uri))) headers))
                         (setf (getf args :max-redirects)
                               (1- max-redirects))
                         (return-from request
                           (apply #'request location-uri args))))))
               (finalize-connection stream (gethash "connection" response-headers) uri)
               (let ((body (decompress-body (gethash "content-encoding" response-headers) body)))
                 (setf body
                       (if force-binary
                           body
                           (decode-body (gethash "content-type" response-headers)
                                        body)))
                 ;; Raise an error when the HTTP response status code is 4xx or 50x.
                 (when (<= 400 status)
                   (http-request-failed-with-restarts status
                                                      :body body
                                                      :headers headers
                                                      :uri uri))
                 (return-from request
                   (values body
                           status
                           response-headers
                           uri
                           (when (and keep-alive
                                      (not (equalp (gethash "connection" response-headers) "close")))
                             stream)))))))))))
