;; Algorithmic Lending Vault Protocol - v2.0.0
;; Added governance system and advanced vault management

(define-constant vault-controller tx-sender)
(define-constant err-controller-only (err u100))
(define-constant err-invalid-cryptoproof (err u101))
(define-constant err-invalid-transaction (err u102))
(define-constant err-protocol-locked (err u103))
(define-constant err-unauthorized-vault (err u104))
(define-constant err-collateral-expired (err u105))
(define-constant err-insufficient-collateral (err u106))
(define-constant err-invalid-parameter (err u107))
(define-constant err-improvement-denied (err u108))
(define-constant err-invalid-interest-rate (err u109))

;; Data Variables
(define-data-var protocol-locked bool false)
(define-map transaction-registry principal uint)
(define-map lending-vaults principal {
    health-factor: uint, 
    total-collateral: uint, 
    operational: bool, 
    min-collateral: uint,
    interest-rate: uint,
    last-update-time: uint
})

(define-map collateral-registry 
    uint 
    {borrower: principal, 
     vault-id: (string-ascii 64),
     tx-id: uint,
     timestamp: uint,
     cryptoproof: (buff 65),
     amount: uint,
     verified: bool,
     interest-paid: uint})

(define-map protocol-improvements 
    uint 
    {improvement-id: uint,
     author: principal,
     description: (string-ascii 256),
     improvement-category: (string-ascii 64),
     parameter: uint,
     for-votes: uint,
     against-votes: uint,
     start-block: uint,
     end-block: uint,
     implemented: bool})

(define-map borrower-analytics
    principal
    {total-collateral: uint,
     active-loans: uint,
     total-interest: uint,
     last-activity: uint})

(define-map improvement-votes
    {improvement-id: uint, voter: principal}
    {for-vote: bool})

(define-data-var registry-counter uint u0)
(define-data-var improvement-counter uint u0)
(define-data-var liquidation-window uint u144) ;; Default 24 hours (144 blocks)
(define-data-var max-min-collateral uint u1000000) 
(define-data-var base-interest-rate uint u100) ;; Base interest rate (x100 for precision)
(define-data-var improvement-threshold uint u5) ;; Minimum votes required
(define-data-var voting-timeframe uint u720) ;; Default 5 days (720 blocks)

;; Read-only functions
(define-read-only (get-transaction-id (user principal))
    (default-to u0 (map-get? transaction-registry user)))

(define-read-only (is-locked)
    (var-get protocol-locked))

(define-read-only (get-vault-details (vault principal))
    (map-get? lending-vaults vault))

(define-read-only (get-collateral-details (collateral-id uint))
    (map-get? collateral-registry collateral-id))

(define-read-only (get-protocol-improvement (improvement-id uint))
    (map-get? protocol-improvements improvement-id))

(define-read-only (get-borrower-stats (user principal))
    (default-to 
        {total-collateral: u0, active-loans: u0, total-interest: u0, last-activity: u0}
        (map-get? borrower-analytics user)))

(define-read-only (get-vote-info (improvement-id uint) (voter principal))
    (map-get? improvement-votes {improvement-id: improvement-id, voter: voter}))

(define-read-only (get-protocol-metrics)
    {total-collaterals: (var-get registry-counter),
     total-improvements: (var-get improvement-counter),
     is-locked: (var-get protocol-locked),
     liquidation-window: (var-get liquidation-window),
     max-min-collateral: (var-get max-min-collateral),
     base-interest-rate: (var-get base-interest-rate),
     improvement-threshold: (var-get improvement-threshold),
     voting-timeframe: (var-get voting-timeframe)})

(define-read-only (calculate-interest (collateral-id uint))
    (let ((collateral (unwrap-panic (map-get? collateral-registry collateral-id)))
          (current-block block-height)
          (vault-data (unwrap-panic (get-vault-details tx-sender))))
        (if (get verified collateral)
            (let ((time-locked (- current-block (get timestamp collateral)))
                  (base-interest (* (get amount collateral) (get interest-rate vault-data))))
                (/ (* base-interest time-locked) u10000))
            u0)))

;; Read-only functions for cryptoproof verification
(define-read-only (verify-cryptoproof (message (buff 32)) (cryptoproof (buff 65)) (borrower principal))
    (let ((recovered-public-key (unwrap! (secp256k1-recover? message cryptoproof) false)))
        (is-eq (unwrap! (principal-of? recovered-public-key) false) borrower)))

;; Private functions
(define-private (increment-transaction (user principal))
    (let ((current-tx-id (get-transaction-id user)))
        (map-set transaction-registry 
            user 
            (+ current-tx-id u1))))

(define-private (update-vault-metrics (vault principal) (collateral-amount uint))
    (let ((current-metrics (unwrap-panic (get-vault-details vault))))
        (map-set lending-vaults
            vault
            (merge current-metrics 
                  {health-factor: (+ (get health-factor current-metrics) u1),
                   total-collateral: (+ (get total-collateral current-metrics) collateral-amount),
                   last-update-time: block-height}))))

(define-private (update-borrower-analytics (user principal) (amount uint) (is-deposit bool))
    (let ((current-stats (get-borrower-stats user)))
        (map-set borrower-analytics
            user
            (merge current-stats
                  {total-collateral: (+ (get total-collateral current-stats) (if is-deposit amount u0)),
                   active-loans: (+ (get active-loans current-stats) (if is-deposit amount (- u0 amount))),
                   last-activity: block-height}))))

(define-private (update-borrower-interest (user principal) (interest-amount uint))
    (let ((current-stats (get-borrower-stats user)))
        (map-set borrower-analytics
            user
            (merge current-stats
                  {total-interest: (+ (get total-interest current-stats) interest-amount),
                   last-activity: block-height}))))

(define-private (validate-vault (vault-to-check principal))
    (is-some (get-vault-details vault-to-check)))

(define-private (validate-min-collateral (min-collateral uint))
    (<= min-collateral (var-get max-min-collateral)))

(define-private (validate-timeframe (timeframe uint))
    (and (> timeframe u0) (<= timeframe u1000)))

(define-private (validate-interest-rate (rate uint))
    (and (> rate u0) (<= rate u1000)))

(define-private (implement-protocol-improvement (improvement-id uint))
    (let ((improvement (unwrap-panic (map-get? protocol-improvements improvement-id))))
        (if (and (>= (get for-votes improvement) (var-get improvement-threshold))
                 (> (get for-votes improvement) (get against-votes improvement)))
            (let ((improvement-category (get improvement-category improvement))
                  (parameter (get parameter improvement)))
                (begin
                    (if (is-eq improvement-category "liquidation-window")
                        (var-set liquidation-window parameter)
                        (if (is-eq improvement-category "max-min-collateral")
                            (var-set max-min-collateral parameter)
                            (if (is-eq improvement-category "base-interest-rate")
                                (var-set base-interest-rate parameter)
                                (if (is-eq improvement-category "improvement-threshold")
                                    (var-set improvement-threshold parameter)
                                    (if (is-eq improvement-category "voting-timeframe")
                                        (var-set voting-timeframe parameter)
                                        false)))))
                    true)) ;; Always return true if we executed successfully
            false))) ;; Not enough votes

;; Public functions
(define-public (register-vault (new-vault principal) (minimum-collateral uint) (interest-rate uint))
    (begin
        (asserts! (is-eq vault-controller tx-sender) err-controller-only)
        (asserts! (not (validate-vault new-vault)) err-invalid-parameter)
        (asserts! (validate-min-collateral minimum-collateral) err-invalid-parameter)
        (asserts! (validate-interest-rate interest-rate) err-invalid-interest-rate)
        (ok (map-set lending-vaults
            new-vault
            {health-factor: u0,
             total-collateral: u0,
             operational: true,
             min-collateral: minimum-collateral,
             interest-rate: interest-rate,
             last-update-time: block-height}))))

(define-public (toggle-lock)
    (begin
        (asserts! (is-eq vault-controller tx-sender) err-controller-only)
        (ok (var-set protocol-locked (not (var-get protocol-locked))))))

(define-public (set-liquidation-window (new-timeframe uint))
    (begin
        (asserts! (is-eq vault-controller tx-sender) err-controller-only)
        (asserts! (validate-timeframe new-timeframe) err-invalid-parameter)
        (ok (var-set liquidation-window new-timeframe))))

(define-public (set-max-min-collateral (new-max-min-collateral uint))
    (begin
        (asserts! (is-eq vault-controller tx-sender) err-controller-only)
        (asserts! (> new-max-min-collateral u0) err-invalid-parameter)
        (ok (var-set max-min-collateral new-max-min-collateral))))

(define-public (update-vault-status (target-vault principal) (operational-status bool) (minimum-collateral uint) (interest-rate uint))
    (begin
        (asserts! (is-eq vault-controller tx-sender) err-controller-only)
        (asserts! (validate-vault target-vault) err-invalid-parameter)
        (asserts! (validate-min-collateral minimum-collateral) err-invalid-parameter)
        (asserts! (validate-interest-rate interest-rate) err-invalid-interest-rate)
        (let ((vault-data (unwrap-panic (get-vault-details target-vault))))
            (ok (map-set lending-vaults
                target-vault
                (merge vault-data 
                       {operational: operational-status,
                        min-collateral: minimum-collateral,
                        interest-rate: interest-rate,
                        last-update-time: block-height}))))))

(define-public (deposit-collateral 
    (vault-id (string-ascii 64))
    (cryptoproof (buff 65))
    (amount uint))
    (let
        ((borrower tx-sender)
         (current-tx-id (get-transaction-id borrower))
         (message-hash (sha256 (concat (unwrap-panic (to-consensus-buff? vault-id))
                                     (concat (unwrap-panic (to-consensus-buff? current-tx-id))
                                             (unwrap-panic (to-consensus-buff? amount)))))))
        (asserts! (not (var-get protocol-locked)) err-protocol-locked)
        (asserts! (> amount u0) err-invalid-parameter)
        (asserts! (verify-cryptoproof message-hash cryptoproof borrower) err-invalid-cryptoproof)
        (map-set collateral-registry
            (var-get registry-counter)
            {borrower: borrower,
             vault-id: vault-id,
             tx-id: current-tx-id,
             timestamp: block-height,
             cryptoproof: cryptoproof,
             amount: amount,
             verified: false,
             interest-paid: u0})
        
        ;; Update borrower analytics
        (update-borrower-analytics borrower amount true)
        
        ;; Increment registry counter
        (var-set registry-counter (+ (var-get registry-counter) u1))
        (ok true)))

(define-public (verify-collateral (registry-id uint))
    (let ((collateral (unwrap-panic (map-get? collateral-registry registry-id)))
          (vault tx-sender)
          (vault-data (unwrap! (get-vault-details vault) err-unauthorized-vault))
          (current-height block-height))
        (asserts! (not (var-get protocol-locked)) err-protocol-locked)
        (asserts! (get operational vault-data) err-unauthorized-vault)
        (asserts! (not (get verified collateral)) err-invalid-transaction)
        (asserts! (<= (- current-height (get timestamp collateral)) (var-get liquidation-window)) err-collateral-expired)
        (asserts! (>= (get amount collateral) (get min-collateral vault-data)) err-insufficient-collateral)
        
        ;; Process the collateral
        (map-set collateral-registry
            registry-id
            (merge collateral {verified: true}))
        
        ;; Update transaction and vault stats
        (increment-transaction (get borrower collateral))
        (update-vault-metrics vault (get amount collateral))
        (ok true)))

(define-public (withdraw-collateral (registry-id uint))
    (let ((collateral (unwrap-panic (map-get? collateral-registry registry-id)))
          (borrower tx-sender))
        (asserts! (is-eq borrower (get borrower collateral)) err-controller-only)
        (asserts! (not (get verified collateral)) err-invalid-transaction)
        
        ;; Cancel the collateral
        (map-set collateral-registry
            registry-id
            (merge collateral {verified: true}))
        
        ;; Update borrower analytics
        (update-borrower-analytics borrower (get amount collateral) false)
        
        ;; Update transaction
        (increment-transaction borrower)
        (ok true)))

(define-public (pay-interest (collateral-id uint))
    (let ((collateral (unwrap-panic (map-get? collateral-registry collateral-id)))
          (borrower tx-sender)
          (interest-amount (calculate-interest collateral-id)))
        (asserts! (is-eq borrower (get borrower collateral)) err-controller-only)
        (asserts! (get verified collateral) err-invalid-parameter)
        
        ;; Update interest paid
        (map-set collateral-registry
            collateral-id
            (merge collateral {interest-paid: (+ (get interest-paid collateral) interest-amount)}))
        
        ;; Update borrower analytics
        (update-borrower-interest borrower interest-amount)
        
        (ok interest-amount)))

(define-public (submit-protocol-improvement 
    (description (string-ascii 256))
    (improvement-category (string-ascii 64))
    (parameter uint))
    (begin
        (asserts! (or (is-eq improvement-category "liquidation-window")
                    (is-eq improvement-category "max-min-collateral")
                    (is-eq improvement-category "base-interest-rate")
                    (is-eq improvement-category "improvement-threshold")
                    (is-eq improvement-category "voting-timeframe"))
                err-invalid-parameter)
        
        ;; Validate the parameter based on improvement category
        (asserts! 
            (if (is-eq improvement-category "liquidation-window")
                (validate-timeframe parameter)
                (if (is-eq improvement-category "interest-rate")
                    (validate-interest-rate parameter)
                    true)) ;; Other parameters have fewer restrictions
            err-invalid-parameter)
        
        ;; Create the improvement
        (map-set protocol-improvements
            (var-get improvement-counter)
            {improvement-id: (var-get improvement-counter),
             author: tx-sender,
             description: description,
             improvement-category: improvement-category,
             parameter: parameter,
             for-votes: u0,
             against-votes: u0,
             start-block: block-height,
             end-block: (+ block-height (var-get voting-timeframe)),
             implemented: false})
        
        ;; Increment the improvement counter
        (var-set improvement-counter (+ (var-get improvement-counter) u1))
        (ok (- (var-get improvement-counter) u1)))) ;; Return the improvement ID

(define-public (vote-on-improvement (improvement-id uint) (support-vote bool))
    (let ((improvement (unwrap! (map-get? protocol-improvements improvement-id) err-invalid-parameter))
          (voter tx-sender)
          (current-height block-height))
        
        ;; Check that voting is still open
        (asserts! (< current-height (get end-block improvement)) err-collateral-expired)
        
        ;; Check that the voter hasn't already voted on this improvement
        (asserts! (is-none (get-vote-info improvement-id voter)) err-invalid-transaction)
        
        ;; Record the vote
        (map-set improvement-votes
            {improvement-id: improvement-id, voter: voter}
            {for-vote: support-vote})
        
        ;; Update the vote count
        (map-set protocol-improvements
            improvement-id
            (merge improvement
                  {for-votes: (+ (get for-votes improvement) (if support-vote u1 u0)),
                   against-votes: (+ (get against-votes improvement) (if support-vote u0 u1))}))
        
        (ok true)))

(define-public (execute-improvement (improvement-id uint))
    (let ((improvement (unwrap! (map-get? protocol-improvements improvement-id) err-invalid-parameter))
          (current-height block-height))
        
        ;; Check that voting is closed
        (asserts! (>= current-height (get end-block improvement)) err-invalid-parameter)
        
        ;; Check that the improvement hasn't already been implemented
        (asserts! (not (get implemented improvement)) err-invalid-parameter)
        
        ;; Try to implement the improvement
        (asserts! (implement-protocol-improvement improvement-id) err-improvement-denied)
        
        ;; Mark the improvement as implemented
        (map-set protocol-improvements
            improvement-id
            (merge improvement {implemented: true}))
        
        (ok true)))