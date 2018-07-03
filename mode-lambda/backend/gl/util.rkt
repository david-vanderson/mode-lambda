#lang racket/base
(require opengl
         racket/list
         racket/match
         racket/string
         web-server/templates
         ffi/vector
         ffi/unsafe
         ffi/cvector
         ffi/unsafe/cvector)

;; XXX maybe 410
(define gl-backend-version (make-parameter '3.3))
(define valid-gl-backends '(3.3 es3.1))
(define (gl-es?)
  (eq? 'es3.1 (gl-backend-version)))

(define-syntax-rule (glsl-include p) (include-template p))

(define (make-2dtexture)
  (define Id (glGen glGenTextures))
  (with-texture (GL_TEXTURE0 Id)
    (2D-defaults GL_TEXTURE_2D))
  Id)

(define (load-texture/bytes w h bs)
  (define the-copy (bytes-copy bs))
  (argb->rgba! the-copy)
  (glTexImage2D GL_TEXTURE_2D
                0 GL_RGBA
                w h 0
                GL_RGBA GL_UNSIGNED_BYTE
                the-copy))

(define (load-texture/float-bytes w h bs)
  (glTexImage2D GL_TEXTURE_2D
                0 GL_RGBA32F
                ;; w is in float values, but RGBA32F is 4 float
                ;; values, so we need to do a fourth of this.
                (ceiling (/ w 4)) h 0
                GL_RGBA GL_FLOAT
                bs))

(define (2D-defaults kind)
  (glTexParameteri kind GL_TEXTURE_MIN_FILTER GL_NEAREST)
  (glTexParameteri kind GL_TEXTURE_MAG_FILTER GL_NEAREST)
  (glTexParameteri kind GL_TEXTURE_WRAP_S GL_CLAMP_TO_EDGE)
  (glTexParameteri kind GL_TEXTURE_WRAP_T GL_CLAMP_TO_EDGE))

(define (gl-texture-index i)
  (- i GL_TEXTURE0))

(define GL_COLOR_ATTACHMENTx
  (vector GL_COLOR_ATTACHMENT0 GL_COLOR_ATTACHMENT1 GL_COLOR_ATTACHMENT2
          GL_COLOR_ATTACHMENT3 GL_COLOR_ATTACHMENT4 GL_COLOR_ATTACHMENT5
          GL_COLOR_ATTACHMENT6 GL_COLOR_ATTACHMENT7))
(define (GL_COLOR_ATTACHMENTi i)
  (vector-ref GL_COLOR_ATTACHMENTx i))

(define (GL_TEXTUREi i)
  (unless (< i 32)
    (error 'GL_TEXTUREi "No valid constant for i=~a" i))
  (+ GL_TEXTURE0 i))

(define-syntax-rule (wrapper (before ...) (middle ...) (after ...))
  (let () before ... middle ... after ...))

(define-syntax-rule (define-with-state with-state (F static-arg ...))
  (define-syntax-rule (with-state (dyn-arg (... ...)) . body)
    (wrapper [(F static-arg ... dyn-arg (... ...))]
             body
             [(F static-arg ... 0)])))

(define-with-state with-program (glUseProgram))
(define-with-state with-vertexarray (glBindVertexArray))
(define-syntax-rule (with-texture (GL_TEXTUREx TextureId) . body)
  (wrapper [(glActiveTexture GL_TEXTUREx)
            (glBindTexture GL_TEXTURE_2D TextureId)]
           body
           [(glActiveTexture GL_TEXTUREx)
            (glBindTexture GL_TEXTURE_2D 0)]))
(define-syntax-rule (with-texture-array (GL_TEXTUREx TextureId) . body)
  (wrapper [(glActiveTexture GL_TEXTUREx)
            (glBindTexture GL_TEXTURE_2D_ARRAY TextureId)]
           body
           [(glActiveTexture GL_TEXTUREx)
            (glBindTexture GL_TEXTURE_2D_ARRAY 0)]))
(define-with-state with-framebuffer (glBindFramebuffer GL_FRAMEBUFFER))
(define-with-state with-renderbuffer (glBindRenderbuffer GL_RENDERBUFFER))
(define-with-state with-arraybuffer (glBindBuffer GL_ARRAY_BUFFER))

(define-syntax-rule (with-feature (FLAG) . body)
  (wrapper [(glEnable FLAG)] body [(glDisable FLAG)]))

(define-syntax-rule (with-vertex-attributes (AttributeCount) . body)
  (wrapper [(for ([i (in-range AttributeCount)])
              (glEnableVertexAttribArray i))]
           body
           [(for ([i (in-range AttributeCount)])
              (glDisableVertexAttribArray i))]))

(define-syntax-rule (with-textures (start-idx ids) . body)
  (with-textures* start-idx ids (λ () . body)))
(define (with-textures* start-idx ids t)
  (if (empty? ids)
    (t)
    (with-texture ((GL_TEXTUREi start-idx) (first ids))
      (with-textures* (+ 1 start-idx) (rest ids) t))))

(define (glGen glGenThing)
  (u32vector-ref (glGenThing 1) 0))

(define-syntax-rule (define-shader-source id path)
  (define id (include-template path)))

(define (print-shader-log glGetShaderInfoLog shader-name shader-id shader-source)
  (define-values (infoLen infoLog)
    (glGetShaderInfoLog shader-id 1024))
  (unless (zero? infoLen)
    (eprintf "Log of shader(~a):\n" shader-name)
    (define real-log (bytes->string/utf-8 (subbytes infoLog 0 infoLen)))
    (define shader-lines (string-split shader-source "\n"))
    (for ([l (in-list (string-split real-log "\n"))])
      (eprintf "\t~a\n" l)
      (match (regexp-match #rx"^0\\(([0-9]*?)\\) : " l)
        [(list _ ns)
         (eprintf "\t\t=> ~a\n"
                  (list-ref shader-lines (sub1 (string->number ns))))]
        [_
         (void)]))
    (eprintf "Shader source follows:\n~a\n"
             shader-source)))

(define (compile-shader GL_VERTEX_SHADER ProgramId VertexShader)
  (define VertexShaderId (glCreateShader GL_VERTEX_SHADER))
  (glShaderSource VertexShaderId 1
                  (vector
                   (string-append (format "#version ~a\n"
                                          (match (gl-backend-version)
                                            ['3.3 "330 core"]
                                            ['es3.1 "310 es"]))
                                  VertexShader))
                  (s32vector))
  (glCompileShader VertexShaderId)
  (unless (= GL_TRUE (glGetShaderiv VertexShaderId GL_COMPILE_STATUS))
    (print-shader-log glGetShaderInfoLog ProgramId VertexShaderId VertexShader)
    (error 'compile-shader "failed to compile ~a shader ~v"
           (if (= GL_FRAGMENT_SHADER GL_VERTEX_SHADER)
             "fragment"
             "vertex")
           ProgramId))
  (glAttachShader ProgramId VertexShaderId))

;; COPIED FROM opengl/main
;; Convert argb -> rgba
;; Modern wisdom is not to convert to rgba but rather use
;; GL_BGRA with GL_UNSIGNED_INT_8_8_8_8_REV. But that turns out not
;; to work on some implementations, even ones which advertise
;; OpenGL 1.2 support. Great.
(define (argb->rgba! pixels)
  (for ((i (in-range (/ (bytes-length pixels) 4))))
    (let* ((offset (* 4 i))
           (alpha (bytes-ref pixels (+ 0 offset)))
           (  red (bytes-ref pixels (+ 1 offset)))
           (green (bytes-ref pixels (+ 2 offset)))
           ( blue (bytes-ref pixels (+ 3 offset))))
      (bytes-set! pixels (+ 0 offset) red)
      (bytes-set! pixels (+ 1 offset) green)
      (bytes-set! pixels (+ 2 offset) blue)
      (bytes-set! pixels (+ 3 offset) alpha))))
;; </COPIED>

(define (rgba->argb! pixels)
  (for ((i (in-range (/ (bytes-length pixels) 4))))
    (let* ((offset (* 4 i))
           (  red (bytes-ref pixels (+ 0 offset)))
           (green (bytes-ref pixels (+ 1 offset)))
           ( blue (bytes-ref pixels (+ 2 offset)))
           (alpha (bytes-ref pixels (+ 3 offset))))
      (bytes-set! pixels (+ 0 offset) alpha)
      (bytes-set! pixels (+ 1 offset) red)
      (bytes-set! pixels (+ 2 offset) green)
      (bytes-set! pixels (+ 3 offset) blue))))

(define (ctype->glsl-type _type)
  (match _type
    [(== _float) "float"]
    [(or (== _byte) (== _ushort) (== _uint32)) "uint"]
    [(or (== _int8) (== _short)) "int"]))

(define (ctype->gl-type _type)
  (match _type
    [(== _float) GL_FLOAT]
    [(== _byte) GL_UNSIGNED_BYTE]
    [(== _int8) GL_BYTE]
    [(== _uint32) GL_UNSIGNED_INT]
    [(== _ushort) GL_UNSIGNED_SHORT]
    [(== _short) GL_SHORT]))

(define (cstruct-info->glsl-in fields)
  (for/list ([f (in-list fields)])
    (match-define (cons id _type) f)
    (list "in " (ctype->glsl-type _type) " " id ";\n")))

(define (bind-attribs/cstruct-info ProgramId fields)
  (for ([i (in-naturals)]
        [f (in-list fields)])
    (match-define (cons id _type) f)
    (glBindAttribLocation ProgramId i (symbol->string id))))

(define (define-attribs/cstruct-info divisor fields)
  (define total-size (apply + (map (compose1 ctype-sizeof cdr) fields)))
  (for/fold ([byte-offset 0])
            ([i (in-naturals)]
             [f (in-list fields)])
    (match-define (cons id _type) f)
    (define int? (not (eq? _type _float)))
    (define this-size (ctype-sizeof _type))
    (define gl-type (ctype->gl-type _type))
    ((if int? glVertexAttribIPointer* glVertexAttribPointer)
     i 1 gl-type #f total-size byte-offset)
    (glVertexAttribDivisor i divisor)
    (+ byte-offset this-size)))

(define (glVertexAttribIPointer* index size type normalized stride pointer)
  (glVertexAttribIPointer index size type stride pointer))

(define (glLinkProgram& ProgramId ProgramName)
  (glLinkProgram ProgramId)
  (unless (= GL_TRUE (glGetProgramiv ProgramId GL_LINK_STATUS))
    (print-shader-log glGetProgramInfoLog ProgramId ProgramId "[inside linking]")
    (error 'glLinkProgram& "failed to link program ~v" ProgramId)))
(define (glValidateProgram& ProgramId ProgramName)
  (glValidateProgram ProgramId)
  (unless (= GL_TRUE (glGetProgramiv ProgramId GL_VALIDATE_STATUS))
    (print-shader-log glGetProgramInfoLog ProgramId ProgramId "[during validation]")
    (error 'glValidateProgram& "failed to validate program ~v" ProgramName)))

(define (make-target-texture width height)
  (define myTexture (glGen glGenTextures))
  (with-texture (GL_TEXTURE0 myTexture)
    (2D-defaults GL_TEXTURE_2D)
    (glTexImage2D
     GL_TEXTURE_2D 0 GL_RGBA8 width height 0
     GL_RGBA GL_UNSIGNED_BYTE
     0))
  myTexture)

(define (make-target-texture-array width height layer-count)
  (define myTexture (glGen glGenTextures))
  (with-texture-array (GL_TEXTURE0 myTexture)
    (2D-defaults GL_TEXTURE_2D_ARRAY)
    (glTexImage3D
     GL_TEXTURE_2D_ARRAY 0 GL_RGBA8 width height layer-count 0
     GL_RGBA GL_UNSIGNED_BYTE
     0))
  myTexture)

(define (num->nearest-pow2 x)
  (expt 2 (integer-length (inexact->exact (ceiling x)))))

(define (pair->fpair w h)
  (f32vector w h))
(define (set-uniform-fpair! program-id uniform-name the-fpair)
  (glUniform2fv (glGetUniformLocation program-id uniform-name) 1 the-fpair))
(struct scale-info (logical x-scale y-scale scaled texture screen))
(define (set-uniform-scale-info! program-id si)
  (match-define (scale-info logical x-scale y-scale scaled texture screen) si)
  (set-uniform-fpair! program-id "LogicalSize" logical)
  (glUniform1f (glGetUniformLocation program-id "XScale") x-scale)
  (glUniform1f (glGetUniformLocation program-id "YScale") y-scale)
  (set-uniform-fpair! program-id "ScaledSize" scaled)
  (set-uniform-fpair! program-id "TextureSize" texture)
  (set-uniform-fpair! program-id "ScreenSize" screen))

(define (set-viewport/fpair! the-fp)
  (define width (inexact->exact (f32vector-ref the-fp 0)))
  (define height (inexact->exact (f32vector-ref the-fp 1)))
  (glViewport 0 0 width height))

(struct delayed-fbo (layer-count [tex #:mutable] [gl-fbo #:mutable]))
(define (make-delayed-fbo layer-count)
  (delayed-fbo layer-count #f #f))
(define (initialize-dfbo! dfbo the-si)
  (match-define (delayed-fbo layer-count tex fbo) dfbo)

  (define the-fp (scale-info-texture the-si))
  (define tex-width (inexact->exact (f32vector-ref the-fp 0)))
  (define tex-height (inexact->exact (f32vector-ref the-fp 1)))

  (when fbo
    (glDeleteFramebuffers 1 (u32vector fbo)))
  (when tex
    (glDeleteTextures 1 (u32vector tex)))
  (define new-tex
    (if (= 1 layer-count)
      (make-target-texture tex-width tex-height)
      (make-target-texture-array tex-width tex-height layer-count)))

  (set-delayed-fbo-tex! dfbo new-tex)
  (set-delayed-fbo-gl-fbo! dfbo (glGen glGenFramebuffers)))

(define (delayed-fbo-fbo dfbo active-layer)
  (match-define (delayed-fbo layer-count tex fbo) dfbo)
  (with-framebuffer (fbo)
    (if (= 1 layer-count)
      (glFramebufferTexture2D GL_DRAW_FRAMEBUFFER
                              GL_COLOR_ATTACHMENT0
                              GL_TEXTURE_2D tex 0)
      (glFramebufferTextureLayer GL_DRAW_FRAMEBUFFER
                                 GL_COLOR_ATTACHMENT0
                                 tex 0 active-layer)))
  fbo)

(define-syntax-rule (define-make-delayed-render
                      delayed-render
                      make-real-render
                      (static-arg ...)
                      (init-arg ...)
                      (dyn-arg ...))
  (define (delayed-render static-arg ...)
    (define draw #f)
    (define last-glctx #f)
    (λ (dyn-arg ... #:r [r 0] #:g [g 0] #:b [b 0])
      (λ (w h dc)
        (local-require racket/class)
        (define glctx (send dc get-gl-context))
        (unless glctx
          (error 'draw "Could not initialize OpenGL!"))
        (send glctx call-as-current
              (λ ()
                (unless (eq? glctx last-glctx)
                  (eprintf "GL context changed\n")
                  (set! draw #f))
                (unless draw
                  (set! last-glctx glctx)
                  (set! draw (make-real-render static-arg ... init-arg ...)))
                (draw w h dyn-arg ... r g b)
                (send glctx swap-buffers)))))))

(define-syntax-rule (print-ms-time label e)
  (let ([before (current-inexact-milliseconds)])
    (begin0
        e
      (let ([after (current-inexact-milliseconds)])
        (printf "~a time ~a\n" label (- after before))))))

(define (make-update-vbo-buffer-with-objects! _sprite-data layer-vbo)
  (local-require racket/fixnum
                 mode-lambda/util)
  (define which 0)

  (define (install-object! o)
    (cvector-set! SpriteData which o)
    (set! which (fx+ which 1)))

  (define (install-objects! t)
    (set! which 0)
    (tree-for install-object! t))

  (define SpriteData-count 0)
  (define *initialize-count* 512)
  (define SpriteData #f)
  (define SpriteData-ptr #f)

  (λ (objects)
    (define early-count (count-objects objects))
    (define SpriteData-count:new (fxmax *initialize-count* early-count))
    (with-arraybuffer (layer-vbo)
      (unless (>= SpriteData-count SpriteData-count:new)
        (set! SpriteData-count
              (fxmax (fx* 2 SpriteData-count)
                     SpriteData-count:new))
        (define new-size
          (* SpriteData-count
             (ctype-sizeof _sprite-data)))
        #;(eprintf "Allocating ~a on GPU\n" new-size)
        (glBufferData GL_ARRAY_BUFFER
                      new-size
                      #f
                      GL_STREAM_DRAW))


      (set! SpriteData-ptr
            (glMapBufferRange
             GL_ARRAY_BUFFER
             0
             (fx* SpriteData-count
                  (ctype-sizeof _sprite-data))
             (bitwise-ior
              ;; We are overriding everything (this would be wrong if
              ;; we did the caching "optimization" I imagine)
              GL_MAP_INVALIDATE_RANGE_BIT
              GL_MAP_INVALIDATE_BUFFER_BIT

              ;; We are not doing complex queues, so don't block other
              ;; operations (but it doesn't seem to improve performance
              ;; by having this option)
              ;; GL_MAP_UNSYNCHRONIZED_BIT

              ;; We are writing
              GL_MAP_WRITE_BIT)))
      (set! SpriteData
            (make-cvector*
             SpriteData-ptr
             _sprite-data
             SpriteData-count))

      (install-objects! objects)
      (glUnmapBuffer GL_ARRAY_BUFFER))
    early-count))

(provide
 (all-defined-out))
