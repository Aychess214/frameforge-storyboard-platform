;; FrameForge: Storyboard Platform Smart Contract
;; This contract serves as the core of the FrameForge platform, enabling filmmakers and content creators
;; to mint, manage, and collaborate on storyboard frames as NFTs on the Stacks blockchain.
;; The contract handles ownership, metadata, collaboration permissions, and royalty distribution.

;; Error Codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-FRAME-NOT-FOUND (err u101))
(define-constant ERR-SEQUENCE-NOT-FOUND (err u102))
(define-constant ERR-INVALID-ROLE (err u103))
(define-constant ERR-ALREADY-EXISTS (err u104))
(define-constant ERR-FRAME-LOCKED (err u105))
(define-constant ERR-INVALID-ROYALTY (err u106))
(define-constant ERR-NOT-COLLABORATOR (err u107))
(define-constant ERR-INSUFFICIENT-FUNDS (err u108))
(define-constant ERR-INVALID-PARAMETERS (err u109))
(define-constant ERR-NOT-OWNER (err u110))

;; Roles
(define-constant ROLE-OWNER u1)
(define-constant ROLE-EDITOR u2)
(define-constant ROLE-VIEWER u3)

;; Data Maps and Variables

;; Track the total number of frames created
(define-data-var frame-id-counter uint u0)

;; Track the total number of sequences created
(define-data-var sequence-id-counter uint u0)

;; Frame metadata map: frame-id -> frame details
(define-map frames 
  { frame-id: uint }
  {
    owner: principal,
    creator: principal,
    metadata-url: (string-utf8 256),
    scene-description: (string-utf8 1024),
    camera-angle: (string-utf8 128),
    production-notes: (string-utf8 1024),
    locked: bool,
    royalty-percentage: uint,
    sequence-id: (optional uint)
  }
)

;; Sequence map: sequence-id -> sequence details
(define-map sequences
  { sequence-id: uint }
  {
    owner: principal,
    creator: principal,
    title: (string-utf8 256),
    description: (string-utf8 1024),
    frame-count: uint,
    locked: bool,
    royalty-percentage: uint
  }
)

;; Sequence frames: sequence-id -> {index -> frame-id}
(define-map sequence-frames
  { sequence-id: uint }
  { frame-ids: (list 100 uint) }
)

;; Collaborators: Maps a frame/sequence to a list of collaborators and their roles
(define-map collaborators
  { asset-type: (string-ascii 10), asset-id: uint }
  { collaborator-roles: (list 20 { collaborator: principal, role: uint }) }
)

;; Licensing records
(define-map licenses
  { asset-type: (string-ascii 10), asset-id: uint, licensee: principal }
  {
    licensor: principal,
    start-block: uint,
    end-block: (optional uint),
    terms: (string-utf8 1024),
    payment: uint
  }
)

;; Private Functions

;; Generate a new frame ID
(define-private (generate-frame-id)
  (let ((current-id (var-get frame-id-counter)))
    (var-set frame-id-counter (+ current-id u1))
    current-id
  )
)

;; Generate a new sequence ID
(define-private (generate-sequence-id)
  (let ((current-id (var-get sequence-id-counter)))
    (var-set sequence-id-counter (+ current-id u1))
    current-id
  )
)

;; Check if caller is the owner of a frame
(define-private (is-frame-owner (frame-id uint) (caller principal))
  (match (map-get? frames { frame-id: frame-id })
    frame-data (is-eq (get owner frame-data) caller)
    false
  )
)

;; Check if caller is the owner of a sequence
(define-private (is-sequence-owner (sequence-id uint) (caller principal))
  (match (map-get? sequences { sequence-id: sequence-id })
    sequence-data (is-eq (get owner sequence-data) caller)
    false
  )
)

;; Check if caller has a specific role for an asset
(define-private (has-role (asset-type (string-ascii 10)) (asset-id uint) (caller principal) (required-role uint))
  (let ((collaborator-list (get-collaborators asset-type asset-id)))
    (match (filter is-caller-with-role collaborator-list)
      filtered-list (> (len filtered-list) u0)
      false
    )
  )
  (where is-caller-with-role (lambda (entry)
    (and
      (is-eq (get collaborator entry) caller)
      (is-eq (get role entry) required-role)
    )
  ))
)

;; Check if caller is owner or has editor role
(define-private (can-edit (asset-type (string-ascii 10)) (asset-id uint) (caller principal))
  (or
    (if (is-eq asset-type "frame")
      (is-frame-owner asset-id caller)
      (is-sequence-owner asset-id caller)
    )
    (has-role asset-type asset-id caller ROLE-EDITOR)
  )
)

;; Calculate royalty amount
(define-private (calculate-royalty (amount uint) (percentage uint))
  (/ (* amount percentage) u10000)
)

;; Read-Only Functions

;; Get frame details
(define-read-only (get-frame (frame-id uint))
  (match (map-get? frames { frame-id: frame-id })
    frame (ok frame)
    ERR-FRAME-NOT-FOUND
  )
)

;; Get sequence details
(define-read-only (get-sequence (sequence-id uint))
  (match (map-get? sequences { sequence-id: sequence-id })
    sequence (ok sequence)
    ERR-SEQUENCE-NOT-FOUND
  )
)

;; Get frames in a sequence
(define-read-only (get-sequence-frames (sequence-id uint))
  (match (map-get? sequence-frames { sequence-id: sequence-id })
    frame-list (ok (get frame-ids frame-list))
    (ok (list))
  )
)

;; Get collaborators for an asset
(define-read-only (get-collaborators (asset-type (string-ascii 10)) (asset-id uint))
  (match (map-get? collaborators { asset-type: asset-type, asset-id: asset-id })
    collab-data (get collaborator-roles collab-data)
    (list)
  )
)

;; Check if a principal has a license for an asset
(define-read-only (has-license (asset-type (string-ascii 10)) (asset-id uint) (licensee principal))
  (match (map-get? licenses { asset-type: asset-type, asset-id: asset-id, licensee: licensee })
    license-data 
      (let ((current-block block-height)
            (end-block (get end-block license-data)))
        (ok (match end-block
          end (< current-block end)
          true))
      )
    (err false)
  )
)

;; Public Functions

;; Create a new storyboard frame
(define-public (create-frame (metadata-url (string-utf8 256)) 
                           (scene-description (string-utf8 1024)) 
                           (camera-angle (string-utf8 128)) 
                           (production-notes (string-utf8 1024))
                           (royalty-percentage uint))
  (let ((frame-id (generate-frame-id))
        (caller tx-sender))
    
    ;; Validate royalty percentage (max 50%)
    (asserts! (<= royalty-percentage u5000) ERR-INVALID-ROYALTY)
    
    ;; Store frame data
    (map-set frames
      { frame-id: frame-id }
      {
        owner: caller,
        creator: caller,
        metadata-url: metadata-url,
        scene-description: scene-description,
        camera-angle: camera-angle,
        production-notes: production-notes,
        locked: false,
        royalty-percentage: royalty-percentage,
        sequence-id: none
      }
    )
    
    (ok frame-id)
  )
)

;; Create a new storyboard sequence
(define-public (create-sequence (title (string-utf8 256)) 
                              (description (string-utf8 1024))
                              (initial-frame-ids (list 100 uint))
                              (royalty-percentage uint))
  (let ((sequence-id (generate-sequence-id))
        (caller tx-sender)
        (frame-count (len initial-frame-ids)))
    
    ;; Validate royalty percentage (max 50%)
    (asserts! (<= royalty-percentage u5000) ERR-INVALID-ROYALTY)
    
    ;; Store sequence data
    (map-set sequences
      { sequence-id: sequence-id }
      {
        owner: caller,
        creator: caller,
        title: title,
        description: description,
        frame-count: frame-count,
        locked: false,
        royalty-percentage: royalty-percentage
      }
    )
    
    ;; Store sequence frames
    (map-set sequence-frames
      { sequence-id: sequence-id }
      { frame-ids: initial-frame-ids }
    )
    
    ;; Update each frame to be part of this sequence
    (map update-frame-sequence initial-frame-ids)
    
    (ok sequence-id)
  )
  
  (where update-frame-sequence (lambda (frame-id)
    (match (map-get? frames { frame-id: frame-id })
      frame-data
        (begin
          (asserts! (is-eq (get owner frame-data) tx-sender) ERR-NOT-AUTHORIZED)
          (map-set frames
            { frame-id: frame-id }
            (merge frame-data { sequence-id: (some sequence-id) })
          )
          true
        )
      false
    )
  ))
)

;; Add a frame to a sequence
(define-public (add-frame-to-sequence (sequence-id uint) (frame-id uint))
  (let ((caller tx-sender))
    ;; Check sequence exists
    (asserts! (is-some (map-get? sequences { sequence-id: sequence-id })) ERR-SEQUENCE-NOT-FOUND)
    ;; Check frame exists
    (asserts! (is-some (map-get? frames { frame-id: frame-id })) ERR-FRAME-NOT-FOUND)
    
    ;; Verify caller can edit both the sequence and the frame
    (asserts! (can-edit "sequence" sequence-id caller) ERR-NOT-AUTHORIZED)
    (asserts! (can-edit "frame" frame-id caller) ERR-NOT-AUTHORIZED)
    
    ;; Check sequence not locked
    (asserts! (not (get locked (unwrap! (map-get? sequences { sequence-id: sequence-id }) ERR-SEQUENCE-NOT-FOUND))) ERR-FRAME-LOCKED)
    
    ;; Add frame to sequence
    (match (map-get? sequence-frames { sequence-id: sequence-id })
      sequence-data
        (let ((current-frames (get frame-ids sequence-data))
              (new-frames (unwrap! (as-max-len? (append current-frames frame-id) u100) ERR-INVALID-PARAMETERS)))
          
          ;; Update sequence frames
          (map-set sequence-frames
            { sequence-id: sequence-id }
            { frame-ids: new-frames }
          )
          
          ;; Update sequence frame count
          (match (map-get? sequences { sequence-id: sequence-id })
            seq-data
              (map-set sequences
                { sequence-id: sequence-id }
                (merge seq-data { frame-count: (+ (get frame-count seq-data) u1) })
              )
            (err ERR-SEQUENCE-NOT-FOUND)
          )
          
          ;; Update frame's sequence reference
          (match (map-get? frames { frame-id: frame-id })
            frame-data
              (map-set frames
                { frame-id: frame-id }
                (merge frame-data { sequence-id: (some sequence-id) })
              )
            (err ERR-FRAME-NOT-FOUND)
          )
          
          (ok true)
        )
      (err ERR-SEQUENCE-NOT-FOUND)
    )
  )
)

;; Update frame metadata
(define-public (update-frame (frame-id uint)
                           (metadata-url (optional (string-utf8 256)))
                           (scene-description (optional (string-utf8 1024)))
                           (camera-angle (optional (string-utf8 128)))
                           (production-notes (optional (string-utf8 1024))))
  (let ((caller tx-sender))
    (match (map-get? frames { frame-id: frame-id })
      frame-data
        (begin
          ;; Check authorization
          (asserts! (can-edit "frame" frame-id caller) ERR-NOT-AUTHORIZED)
          ;; Check not locked
          (asserts! (not (get locked frame-data)) ERR-FRAME-LOCKED)
          
          ;; Update fields only if provided
          (map-set frames
            { frame-id: frame-id }
            (merge frame-data 
              {
                metadata-url: (default-to (get metadata-url frame-data) metadata-url),
                scene-description: (default-to (get scene-description frame-data) scene-description),
                camera-angle: (default-to (get camera-angle frame-data) camera-angle),
                production-notes: (default-to (get production-notes frame-data) production-notes)
              }
            )
          )
          
          (ok true)
        )
      (err ERR-FRAME-NOT-FOUND)
    )
  )
)

;; Add a collaborator to a frame or sequence
(define-public (add-collaborator (asset-type (string-ascii 10)) 
                               (asset-id uint) 
                               (collaborator principal) 
                               (role uint))
  (let ((caller tx-sender))
    ;; Validate asset type
    (asserts! (or (is-eq asset-type "frame") (is-eq asset-type "sequence")) ERR-INVALID-PARAMETERS)
    
    ;; Validate role
    (asserts! (or (is-eq role ROLE-EDITOR) (is-eq role ROLE-VIEWER)) ERR-INVALID-ROLE)
    
    ;; Check caller is owner
    (asserts! 
      (if (is-eq asset-type "frame")
        (is-frame-owner asset-id caller)
        (is-sequence-owner asset-id caller)
      )
      ERR-NOT-AUTHORIZED
    )
    
    ;; Add collaborator
    (match (map-get? collaborators { asset-type: asset-type, asset-id: asset-id })
      existing-data
        (let ((current-collaborators (get collaborator-roles existing-data))
              (new-entry { collaborator: collaborator, role: role })
              (new-collaborators (unwrap! (as-max-len? (append current-collaborators new-entry) u20) ERR-INVALID-PARAMETERS)))
          (map-set collaborators
            { asset-type: asset-type, asset-id: asset-id }
            { collaborator-roles: new-collaborators }
          )
        )
      ;; No existing collaborators, create new entry
      (map-set collaborators
        { asset-type: asset-type, asset-id: asset-id }
        { collaborator-roles: (list { collaborator: collaborator, role: role }) }
      )
    )
    
    (ok true)
  )
)

;; Transfer ownership of a frame
(define-public (transfer-frame (frame-id uint) (new-owner principal))
  (let ((caller tx-sender))
    (match (map-get? frames { frame-id: frame-id })
      frame-data
        (begin
          ;; Check ownership
          (asserts! (is-eq (get owner frame-data) caller) ERR-NOT-OWNER)
          
          ;; Update ownership
          (map-set frames
            { frame-id: frame-id }
            (merge frame-data { owner: new-owner })
          )
          
          (ok true)
        )
      (err ERR-FRAME-NOT-FOUND)
    )
  )
)

;; Transfer ownership of a sequence
(define-public (transfer-sequence (sequence-id uint) (new-owner principal))
  (let ((caller tx-sender))
    (match (map-get? sequences { sequence-id: sequence-id })
      sequence-data
        (begin
          ;; Check ownership
          (asserts! (is-eq (get owner sequence-data) caller) ERR-NOT-OWNER)
          
          ;; Update ownership
          (map-set sequences
            { sequence-id: sequence-id }
            (merge sequence-data { owner: new-owner })
          )
          
          (ok true)
        )
      (err ERR-SEQUENCE-NOT-FOUND)
    )
  )
)

;; Lock a frame to prevent further changes (e.g., when finalizing)
(define-public (lock-frame (frame-id uint))
  (let ((caller tx-sender))
    (match (map-get? frames { frame-id: frame-id })
      frame-data
        (begin
          ;; Check ownership
          (asserts! (is-eq (get owner frame-data) caller) ERR-NOT-OWNER)
          
          ;; Update lock status
          (map-set frames
            { frame-id: frame-id }
            (merge frame-data { locked: true })
          )
          
          (ok true)
        )
      (err ERR-FRAME-NOT-FOUND)
    )
  )
)

;; Create a license for a frame or sequence
(define-public (create-license (asset-type (string-ascii 10)) 
                             (asset-id uint) 
                             (licensee principal)
                             (duration (optional uint))
                             (terms (string-utf8 1024))
                             (payment uint))
  (let ((caller tx-sender)
        (current-block block-height))
    
    ;; Validate asset type
    (asserts! (or (is-eq asset-type "frame") (is-eq asset-type "sequence")) ERR-INVALID-PARAMETERS)
    
    ;; Check caller is owner
    (asserts! 
      (if (is-eq asset-type "frame")
        (is-frame-owner asset-id caller)
        (is-sequence-owner asset-id caller)
      )
      ERR-NOT-AUTHORIZED
    )
    
    ;; Calculate end block if duration provided
    (let ((end-block (match duration
                       some-duration (some (+ current-block some-duration))
                       none)))
      
      ;; Record license
      (map-set licenses
        { asset-type: asset-type, asset-id: asset-id, licensee: licensee }
        {
          licensor: caller,
          start-block: current-block,
          end-block: end-block,
          terms: terms,
          payment: payment
        }
      )
      
      (ok true)
    )
  )
)

;; Purchase a license - this function handles both the payment and license creation
(define-public (purchase-license (asset-type (string-ascii 10)) 
                               (asset-id uint) 
                               (duration (optional uint))
                               (terms (string-utf8 1024)))
  (let ((caller tx-sender)
        (asset-owner (if (is-eq asset-type "frame")
                     (get owner (unwrap! (map-get? frames { frame-id: asset-id }) ERR-FRAME-NOT-FOUND))
                     (get owner (unwrap! (map-get? sequences { sequence-id: sequence-id }) ERR-SEQUENCE-NOT-FOUND))))
        (royalty-percentage (if (is-eq asset-type "frame")
                             (get royalty-percentage (unwrap! (map-get? frames { frame-id: asset-id }) ERR-FRAME-NOT-FOUND))
                             (get royalty-percentage (unwrap! (map-get? sequences { sequence-id: sequence-id }) ERR-SEQUENCE-NOT-FOUND))))
        (creator (if (is-eq asset-type "frame")
                   (get creator (unwrap! (map-get? frames { frame-id: asset-id }) ERR-FRAME-NOT-FOUND))
                   (get creator (unwrap! (map-get? sequences { sequence-id: sequence-id }) ERR-SEQUENCE-NOT-FOUND))))
        (payment-amount u10000000)) ;; Set a fixed payment amount (100 STX)
    
    ;; Validate asset type
    (asserts! (or (is-eq asset-type "frame") (is-eq asset-type "sequence")) ERR-INVALID-PARAMETERS)
    
    ;; Calculate royalty
    (let ((royalty-amount (calculate-royalty payment-amount royalty-percentage))
          (owner-amount (- payment-amount royalty-amount)))
      
      ;; Make payment to owner and creator
      (try! (stx-transfer? owner-amount caller asset-owner))
      
      ;; If creator is different from owner, pay royalty to creator
      (if (not (is-eq creator asset-owner))
        (try! (stx-transfer? royalty-amount caller creator))
        true
      )
      
      ;; Create license
      (try! (create-license asset-type asset-id caller duration terms payment-amount))
      
      (ok true)
    )
  )
)