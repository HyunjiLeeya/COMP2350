

drop procedure if exists CheckoutOrder



DELIMITER $$

CREATE PROCEDURE CheckoutOrder
(
    IN  p_OrderID INT,
    IN  p_UserID INT,
    IN  p_RedeemPoints BOOLEAN,
    IN  p_PointsToRedeem INT,                
    IN  p_NonPointsAmount DECIMAL(10,2),    
    IN  p_NonPointsMethodName VARCHAR(20),    -- must exist in PaymentMethod
    OUT o_Status VARCHAR(20),
    OUT o_Message VARCHAR(255)
)
BEGIN
    DECLARE vHasPrimary INT DEFAULT 0;
    DECLARE vOrderTotal DECIMAL(10,2);
    DECLARE vPaid DECIMAL(10,2);
    DECLARE vErr INT DEFAULT 0;

    -- stock & items
    DECLARE vItemsTotal DECIMAL(10,2);

    -- loyalty
    DECLARE vPointsRate DECIMAL(10,4) DEFAULT 0.01; -- $ per point
    DECLARE vUserPoints INT;
    DECLARE vPointsToUse INT;
    DECLARE vPointsValue DECIMAL(10,2);

    -- payment method ids
    DECLARE vPM_LOY INT;
    DECLARE vPM_NONPOINTS INT;

    --  Begin transaction process
    START TRANSACTION;

    --  user must have a valid primary address
    SELECT COUNT(*) INTO vHasPrimary
    FROM UserAddress
    WHERE userID = p_UserID AND isPrimary = TRUE
    FOR UPDATE;

    IF vHasPrimary = 0 THEN
        SET o_Status='FAILURE', o_Message='No valid primary address';
        SET vErr = 1;
    END IF;

    -- 3) Load and lock order, recompute item total 
    IF vErr = 0 THEN
        SELECT co.totalAmount
          INTO vOrderTotal
        FROM CusOrder co
        WHERE co.orderID = p_OrderID AND co.userID = p_UserID
        FOR UPDATE;

        IF vOrderTotal IS NULL THEN
            SET o_Status='FAILURE', o_Message='Order not found or not owned by user';
            SET vErr = 1;
        END IF;
    END IF;

    IF vErr = 0 THEN
        SELECT COALESCE(SUM(oi.quantity * oi.priceAtPurchase), 0.00)
          INTO vItemsTotal
        FROM OrderItem oi
        WHERE oi.orderID = p_OrderID
        FOR UPDATE;

        IF vItemsTotal = 0 THEN
            SET o_Status='FAILURE', o_Message='Order has no items';
            SET vErr = 1;
        END IF;
    END IF;

    --  verify stock for each item (lock product rows), then deduct
    IF vErr = 0 THEN
        IF EXISTS (
            SELECT 1
            FROM OrderItem oi
            JOIN Product pr ON pr.productID = oi.productID
            WHERE oi.orderID = p_OrderID
              AND pr.stockQuantity < oi.quantity
            FOR UPDATE
        ) THEN
            SET o_Status='FAILURE', o_Message='Insufficient stock for one or more items';
            SET vErr = 1;
        ELSE
            UPDATE Product pr
            JOIN OrderItem oi ON oi.productID = pr.productID
            SET pr.stockQuantity = pr.stockQuantity - oi.quantity
            WHERE oi.orderID = p_OrderID;
        END IF;
    END IF;

    -- Resolve PaymentMethod IDs
    IF vErr = 0 THEN
        SELECT paymentMethodID INTO vPM_LOY
        FROM PaymentMethod WHERE methodName = 'Points + Pay' LIMIT 1;

        SELECT paymentMethodID INTO vPM_NONPOINTS
        FROM PaymentMethod WHERE methodName = p_NonPointsMethodName LIMIT 1;

        IF vPM_LOY IS NULL THEN
            SET o_Status='FAILURE', o_Message='PaymentMethod "Points + Pay" missing';
            SET vErr = 1;
        ELSEIF vPM_NONPOINTS IS NULL THEN
            SET o_Status='FAILURE', o_Message=CONCAT('PaymentMethod "', p_NonPointsMethodName, '" missing');
            SET vErr = 1;
        END IF;
    END IF;

    --  loyalty redemption (reduce balance; log transaction; add payment row)
    IF vErr = 0 AND p_RedeemPoints = TRUE AND p_PointsToRedeem > 0 THEN
        -- lock user row to protect loyaltyPoints balance
        SELECT loyaltyPoints INTO vUserPoints
        FROM User
        WHERE userID = p_UserID
        FOR UPDATE;

        IF vUserPoints IS NULL THEN
            SET o_Status='FAILURE', o_Message='User not found for loyalty redemption';
            SET vErr = 1;
        ELSEIF p_PointsToRedeem > vUserPoints THEN
            SET o_Status='FAILURE', o_Message='Insufficient loyalty points';
            SET vErr = 1;
        ELSE
            SET vPointsToUse = p_PointsToRedeem;
            SET vPointsValue = ROUND(vPointsToUse * vPointsRate, 2);

            -- deduct points from User
            UPDATE User
               SET loyaltyPoints = loyaltyPoints - vPointsToUse
             WHERE userID = p_UserID;

            -- log the spend
            INSERT INTO LoyaltyTransaction(userID, orderID, pointsEarned, pointsSpent)
            VALUES (p_UserID, p_OrderID, 0, vPointsToUse);

            -- create a payment row representing the dollar value of points
            INSERT INTO Payment(orderID, paymentMethodID, amountPaid, paymentStatus)
            VALUES (p_OrderID, vPM_LOY, vPointsValue, 'Approved');
        END IF;
    END IF;

    --  Add non-points payment 
    IF vErr = 0 AND p_NonPointsAmount IS NOT NULL AND p_NonPointsAmount > 0 THEN
        INSERT INTO Payment(orderID, paymentMethodID, amountPaid, paymentStatus)
        VALUES (p_OrderID, vPM_NONPOINTS, ROUND(p_NonPointsAmount,2), 'Approved');
    END IF;

    --  approved payments must match order total, +- 0.02 for afterpay 
    IF vErr = 0 THEN
        SELECT ROUND(COALESCE(SUM(amountPaid),0.00),2)
          INTO vPaid
        FROM Payment
        WHERE orderID = p_OrderID AND paymentStatus='Approved';

        IF vPaid - vOrderTotal THEN
            SET o_Status='FAILURE',
                o_Message=CONCAT('Payment mismatch: paid=', vPaid, ' vs due=', vOrderTotal);
            SET vErr = 1;
        END IF;
    END IF;

    -- 9) Success → keep order in 'Processing' (shipping flow later sets 'Delivered')
    IF vErr = 0 THEN
        UPDATE CusOrder
           SET orderStatus = 'Processing'
         WHERE orderID = p_OrderID;

        COMMIT;
        SET o_Status='SUCCESS', o_Message='Checkout successful';
    ELSE
        ROLLBACK;
    END IF;
END $$

DELIMITER ;




INSERT INTO User (userID, userName, email, userPassword, phone, loyaltyPoints, isMember) VALUES
  (9001, 'Nora Vale',   'nora+bncl@test',  'pw', '61 400 9001',  2500, TRUE),  -- 2500 pts = $25.00
  (9002, 'Omar West',   'omar+bncl@test',  'pw', '61 400 9002',   100, TRUE),  -- only 100 pts
  (9003, 'Pia Xu',      'pia+bncl@test',   'pw', '61 400 9003',     0, FALSE), -- no points
  (9004, 'Quinn Yang',  'quinn+bncl@test', 'pw', '61 400 9004',  9999, TRUE),  -- plenty of points
  (9005, 'Ravi Zane',   'ravi+bncl@test',  'pw', '61 400 9005',   200, TRUE),  -- some points
  (9006, 'Sana Arif',   'sana+bncl@test',  'pw', '61 400 9006',  1500, TRUE);  -- 1500 pts = $15.00


INSERT INTO UserAddress (addressID, userID, addressLabel, streetAddress, city, state, postcode, isPrimary) VALUES
  (99001, 9001, 'Home', '1 Nova St',      'Sydney', 'NSW', '2000', TRUE),
  (99002, 9001, 'Work', '10 Harbour Rd',  'Sydney', 'NSW', '2000', FALSE),

  (99011, 9002, 'Old',  '99 Null Ave',    'Sydney', 'NSW', '2000', FALSE),  -- NOT primary (BR1 fail user)

  (99021, 9003, 'Home', '3 Pine Ct',      'Melbourne', 'VIC', '3000', TRUE),
  (99031, 9004, 'Home', '4 River Way',    'Brisbane',  'QLD', '4000', TRUE),
  (99041, 9005, 'Home', '5 Lake Rd',      'Perth',     'WA',  '6000', TRUE),
  (99051, 9006, 'Home', '6 Hill View',    'Adelaide',  'SA',  '5000', TRUE);

-- new products
INSERT INTO Product (productID, productName, productDescription, category, price, stockQuantity, isClearance) VALUES
  (95001, 'Compact Mouse',    'Wireless 2.4G',      'Electronics',  20.00, 100, FALSE),
  (95002, 'USB-C Cable 2m',   'Braided cable',      'Accessories',   8.00, 500, TRUE),
  (95003, 'Over-Ear Headset', 'ANC headset',        'Audio',       120.00,   1, FALSE), -- low stock for 
  (95004, 'LED Desk Lamp',    'Dimmable',           'Home',         23.33, 100, FALSE), -- odd price
  (95005, 'Laptop Stand',     'Aluminum riser',     'Accessories',  29.50,   2, FALSE); -- exact stock test


INSERT INTO CusOrder (orderID, userID, totalAmount, orderStatus, createdAt)
VALUES (97001, 9001, 100.00, 'Processing', NOW());
INSERT INTO OrderItem (orderItemID, orderID, productID, quantity, priceAtPurchase) VALUES
  (995001, 97001, 95001, 2, 20.00),  -- 40.00
  (995002, 97001, 95002, 2, 30.00);  -- 60.00 (promo)  TOTAL 100.00

INSERT INTO CusOrder (orderID, userID, totalAmount, orderStatus, createdAt)
VALUES (97002, 9002, 64.00, 'Processing', NOW());
INSERT INTO OrderItem (orderItemID, orderID, productID, quantity, priceAtPurchase) VALUES
  (995003, 97002, 95002, 8, 8.00);   -- 64.00


INSERT INTO CusOrder (orderID, userID, totalAmount, orderStatus, createdAt)
VALUES (97003, 9004, 240.00, 'Processing', NOW());
INSERT INTO OrderItem (orderItemID, orderID, productID, quantity, priceAtPurchase) VALUES
  (995004, 97003, 95003, 2, 120.00); -- wants 2, only 1 in stock → fail


INSERT INTO CusOrder (orderID, userID, totalAmount, orderStatus, createdAt)
VALUES (97004, 9003, 60.00, 'Processing', NOW());
INSERT INTO OrderItem (orderItemID, orderID, productID, quantity, priceAtPurchase) VALUES
  (995005, 97004, 95001, 3, 20.00);  -- 60.00


INSERT INTO CusOrder (orderID, userID, totalAmount, orderStatus, createdAt)
VALUES (97005, 9004, 69.99, 'Processing', NOW());
INSERT INTO OrderItem (orderItemID, orderID, productID, quantity, priceAtPurchase) VALUES
  (995006, 97005, 95004, 3, 23.33);  -- 3 * 23.33 = 69.99

INSERT INTO CusOrder (orderID, userID, totalAmount, orderStatus, createdAt)
VALUES (97006, 9005, 83.50, 'Processing', NOW());
INSERT INTO OrderItem (orderItemID, orderID, productID, quantity, priceAtPurchase) VALUES
  (995007, 97006, 95005, 1, 29.50),  -- 29.50
  (995008, 97006, 95001, 1, 20.00),  -- 20.00
  (995009, 97006, 95002, 1, 34.00);  -- 34.00 (promo)  TOTAL 83.50

INSERT INTO CusOrder (orderID, userID, totalAmount, orderStatus, createdAt)
VALUES (97007, 9006, 50.33, 'Processing', NOW());
INSERT INTO OrderItem (orderItemID, orderID, productID, quantity, priceAtPurchase) VALUES
  (995010, 97007, 95001, 1, 20.00),  -- 20.00
  (995011, 97007, 95004, 1, 30.33);  -- 30.33
/* Nora used 2× exact prices + one odd to exercise BR2 rounding at 2 decimals. */

/* 97008 — EXACT STOCK SUCCESS (Sana 9006): takes remaining 2 laptop stands (95005 = 2 in stock) */
INSERT INTO CusOrder (orderID, userID, totalAmount, orderStatus, createdAt)
VALUES (97008, 9006, 59.00, 'Processing', NOW());
INSERT INTO OrderItem (orderItemID, orderID, productID, quantity, priceAtPurchase) VALUES
  (995012, 97008, 95005, 2, 29.50);  -- 2 * 29.50 = 59.00 (should reduce stock from 2 → 0)


/* 97001 — SUCCESS: — 2500 pts available; redeem 2500 ($25) + card $75 */
CALL CheckoutOrder(97001, 9001, TRUE, 2500, 75.00, 'Credit Card', @s, @m);
SELECT '97001' AS order_tag, @s AS status, @m AS message;

-- 97002 — BR1: no primary address (Omar 9002) 
CALL CheckoutOrder(97002, 9002, FALSE, 0, 64.00, 'Credit Card', @s, @m);
SELECT '97002' AS order_tag, @s AS status, @m AS message;

-- 97003 — BR5: insufficient stock (Headset wants 2, stock=1) 
CALL CheckoutOrder(97003, 9004, FALSE, 0, 240.00, 'Credit Card', @s, @m);
SELECT '97003' AS order_tag, @s AS status, @m AS message;

-- 97004 — BR2 underpay by $0.01 and test for rounding by 0.02c 
CALL CheckoutOrder(97004, 9003, FALSE, 0, 59.98, 'PayPal', @s, @m);
SELECT '97004' AS order_tag, @s AS status, @m AS message;

-- 97005 — points only 
CALL CheckoutOrder(97005, 9004, TRUE, 6999, 0.00, 'Credit Card', @s, @m);
SELECT '97005' AS order_tag, @s AS status, @m AS message;

-- afterpay
CALL CheckoutOrder(97006, 9005, FALSE, 0, 83.50, 'Afterpay', @s, @m);
SELECT '97006' AS order_tag, @s AS status, @m AS message;

-- less points with card
CALL CheckoutOrder(97007, 9006, TRUE, 33, 50.00, 'Credit Card', @s, @m);
SELECT '97007' AS order_tag, @s AS status, @m AS message;

-- exact stock
CALL CheckoutOrder(97008, 9006, FALSE, 0, 59.00, 'Credit Card', @s, @m);
SELECT '97008' AS order_tag, @s AS status, @m AS message;
