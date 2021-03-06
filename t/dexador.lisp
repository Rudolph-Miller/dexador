(in-package :cl-user)
(defpackage dexador-test
  (:use :cl
        :prove)
  (:import-from :clack.test
                :subtest-app))
(in-package :dexador-test)

(plan 6)

(subtest-app "normal case"
    (lambda (env)
      `(200 (:content-length ,(length (getf env :request-uri))) (,(getf env :request-uri))))
  (subtest "GET"
    (multiple-value-bind (body code headers)
        (dex:get "http://localhost:4242/foo"
                 :headers '((:x-foo . "ppp")))
      (is code 200)
      (is body "/foo")
      (is (gethash "content-length" headers) 4)))
  (subtest "HEAD"
    (multiple-value-bind (body code)
        (dex:head "http://localhost:4242/foo")
      (is code 200)
      (is body "")))
  (subtest "PUT"
    (multiple-value-bind (body code)
        (dex:put "http://localhost:4242/foo")
      (is code 200)
      (is body "/foo")))
  (subtest "DELETE"
    (multiple-value-bind (body code)
        (dex:delete "http://localhost:4242/foo")
      (is code 200)
      (is body "/foo"))))

(subtest-app "redirection"
    (lambda (env)
      (let ((id (parse-integer (subseq (getf env :path-info) 1))))
        (cond
          ((= id 3)
           '(200 (:content-length 2) ("OK")))
          ((<= 300 id 399)
           '(302 (:location "/200") ()))
          ((= id 200)
           (let ((method (princ-to-string (getf env :request-method))))
             `(200 (:content-length ,(length method))
                   (,method))))
          (T
           `(302 (:location ,(format nil "http://localhost:4242/~D" (1+ id))) ())))))
  (subtest "redirect"
    (multiple-value-bind (body code headers)
        (dex:get "http://localhost:4242/1")
      (is code 200)
      (is body "OK")
      (is (gethash "content-length" headers) 2)))
  (subtest "not enough redirect"
    (multiple-value-bind (body code headers)
        (dex:get "http://localhost:4242/1" :max-redirects 0)
      (declare (ignore body))
      (is code 302)
      (is (gethash "location" headers) "http://localhost:4242/2")))
  (subtest "exceed max redirect"
    (multiple-value-bind (body code headers)
        (dex:get "http://localhost:4242/4" :max-redirects 7)
      (declare (ignore body))
      (is code 302)
      (is (gethash "location" headers) "http://localhost:4242/12")))
  (subtest "Don't redirect POST"
    (multiple-value-bind (body code)
        (dex:post "http://localhost:4242/301")
      (declare (ignore body))
      (is code 302))))

(subtest-app "POST request"
    (lambda (env)
      (cond
        ((string= (getf env :path-info) "/upload")
         (let ((buf (make-array (getf env :content-length)
                                :element-type '(unsigned-byte 8))))
           (read-sequence buf (getf env :raw-body))
           `(200 ()
                 (,(babel:octets-to-string buf)))))
        (T
         (let ((req (lack.request:make-request env)))
           `(200 ()
                 (,(with-output-to-string (s)
                     (loop for (k . v) in (lack.request:request-body-parameters req)
                           do (format s "~&~A: ~A~%"
                                      k
                                      (if (and (consp v)
                                               (streamp (car v)))
                                          (let* ((buf (make-array 1024 :element-type '(unsigned-byte 8)))
                                                 (n (read-sequence buf (car v))))
                                            (babel:octets-to-string (subseq buf 0 n)))
                                          v))))))))))
  (subtest "content in alist"
    (multiple-value-bind (body code headers)
        (dex:post "http://localhost:4242/"
                  :content '(("name" . "Eitaro")
                             ("email" . "e.arrows@gmail.com")))
      (declare (ignore headers))
      (is code 200)
      (is body "name: Eitaro
email: e.arrows@gmail.com
")))
  (subtest "multipart"
    (multiple-value-bind (body code)
        (dex:post "http://localhost:4242/"
                  :content `(("title" . "Road to Lisp")
                             ("body" . ,(asdf:system-relative-pathname :dexador #P"t/data/quote.txt"))))
      (is code 200)
      (is body
          "title: Road to Lisp
body: \"Within a couple weeks of learning Lisp I found programming in any other language unbearably constraining.\" -- Paul Graham, Road to Lisp

")))
  (subtest "upload"
    (multiple-value-bind (body code)
        (dex:post "http://localhost:4242/upload"
                  :content (asdf:system-relative-pathname :dexador #P"t/data/quote.txt"))
      (is code 200)
      (is body "\"Within a couple weeks of learning Lisp I found programming in any other language unbearably constraining.\" -- Paul Graham, Road to Lisp
"))))

(subtest-app "HTTP request failed"
    (lambda (env)
      (if (string= (getf env :path-info) "/404")
          '(404 () ("Not Found"))
          '(500 () ("Internal Server Error"))))
  (handler-case
      (progn
        (dex:get "http://localhost:4242/")
        (fail "Must raise an error DEX:HTTP-REQUEST-FAILED"))
    (dex:http-request-failed (e)
      (pass "Raise DEX:HTTP-REQUEST-FAILED error")
      (is (dex:response-status e) 500
          "response status is 500")
      (is (dex:response-body e) "Internal Server Error"
          "response body is \"Internal Server Error\"")))
  (handler-case
      (progn
        (dex:get "http://localhost:4242/404")
        (fail "Must raise an error DEX:HTTP-REQUEST-NOT-FOUND"))
    (dex:http-request-not-found (e)
      (pass "Raise DEX:HTTP-REQUEST-FAILED error")
      (is (dex:response-status e) 404
          "response status is 404")
      (is (dex:response-body e) "Not Found"
          "response body is \"Not Found\""))))

(subtest-app "Using cookies"
    (lambda (env)
      (list (if (string= (getf env :path-info) "/302")
                302
                200)
            ;; mixi.jp
            '(:set-cookie "_auid=a8acafbaef245a806f6a308506dc95c8; domain=localhost; path=/; expires=Mon, 10-Jul-2017 12:32:47 GMT"
              ;; sourceforge
              :set-cookie2 "VISITOR=55a11217d3179d198af1d003; expires=\"Tue, 08-Jul-2025 12:54:47 GMT\"; httponly; Max-Age=315360000; Path=/")
            '("ok")))
  (let ((cookie-jar (cl-cookie:make-cookie-jar)))
    (is (length (cl-cookie:cookie-jar-cookies cookie-jar)) 0 "0 cookies")
    (dex:head "http://localhost:4242/" :cookie-jar cookie-jar)
    (is (length (cl-cookie:cookie-jar-cookies cookie-jar)) 2 "2 cookies")
    (dex:head "http://localhost:4242/" :cookie-jar cookie-jar))

  ;; 302
  (let ((cookie-jar (cl-cookie:make-cookie-jar)))
    (is (length (cl-cookie:cookie-jar-cookies cookie-jar)) 0 "0 cookies")
    (dex:head "http://localhost:4242/302" :cookie-jar cookie-jar)
    (is (length (cl-cookie:cookie-jar-cookies cookie-jar)) 2 "2 cookies")
    (dex:head "http://localhost:4242/302" :cookie-jar cookie-jar)))

(subtest-app "verbose"
    (lambda (env)
      (declare (ignore env))
      '(200 () ("ok")))
  (ok (dex:get "http://localhost:4242/" :verbose t)))

(finalize)
