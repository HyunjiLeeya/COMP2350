
    -- Task4 
    
    -- 4.2.1
    
    DELIMITER $$

CREATE TRIGGER trg_return_accept_refund
AFTER UPDATE ON ReturnedItem
FOR EACH ROW
BEGIN
  DECLARE v_max       DECIMAL(10,2);
  DECLARE v_refunded  DECIMAL(10,2);
  DECLARE v_to_refund DECIMAL(10,2);

  IF NEW.returnStatus = 'Accepted'
     AND (OLD.returnStatus IS NULL OR OLD.returnStatus <> 'Accepted') THEN

    SELECT (oi.quantity * oi.priceAtPurchase)
      INTO v_max
      FROM OrderItem oi
      WHERE oi.orderItemID = NEW.orderItemID;

    IF v_max IS NULL THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Order item not found for the return';
    END IF;

    SELECT COALESCE(SUM(r.refundAmount),0)
      INTO v_refunded
      FROM Refund r
      JOIN ReturnedItem ri ON ri.returnID = r.returnID
      WHERE ri.orderItemID = NEW.orderItemID;

    SET v_to_refund = COALESCE(NEW.refundAmount, v_max - v_refunded);

    IF v_to_refund <= 0 THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No refundable amount remains';
    END IF;

    IF v_refunded + v_to_refund > v_max THEN
      SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Refund exceeds original purchase price';
    END IF;

    INSERT INTO Refund (returnID, refundMethod, refundAmount, processedAt)
    VALUES (NEW.returnID, 'Auto', v_to_refund, NOW());
  END IF;
END $$
DELIMITER ;

    
    -- 4.2.2
    DROP TRIGGER IF EXISTS trg_cusorder_points;
DELIMITER $$

CREATE TRIGGER trg_cusorder_points
AFTER UPDATE ON CusOrder
FOR EACH ROW
BEGIN
  DECLARE v_earned INT DEFAULT 0;
  DECLARE v_spent  INT DEFAULT 0;
  DECLARE v_net    INT DEFAULT 0;
  DECLARE v_points INT;

  SET v_points = FLOOR(NEW.totalAmount * 0.05);

  SELECT COALESCE(SUM(pointsEarned),0), COALESCE(SUM(pointsSpent),0)
    INTO v_earned, v_spent
    FROM LoyaltyTransaction
    WHERE orderID = NEW.orderID;

  SET v_net = v_earned - v_spent;

  IF NEW.orderStatus = 'Delivered' AND OLD.orderStatus <> 'Delivered' THEN
    IF v_net = 0 AND v_points > 0 THEN
      INSERT INTO LoyaltyTransaction (userID, orderID, pointsEarned, pointsSpent, transactionDate)
      VALUES (NEW.userID, NEW.orderID, v_points, 0, NOW());

      UPDATE `User`
      SET loyaltyPoints = loyaltyPoints + v_points
      WHERE userID = NEW.userID;
    END IF;
  END IF;

  IF NEW.orderStatus IN ('Cancelled','Returned')
     AND OLD.orderStatus NOT IN ('Cancelled','Returned') THEN
    IF v_net > 0 THEN
      INSERT INTO LoyaltyTransaction (userID, orderID, pointsEarned, pointsSpent, transactionDate)
      VALUES (NEW.userID, NEW.orderID, 0, v_net, NOW());

      UPDATE `User`
      SET loyaltyPoints = GREATEST(loyaltyPoints - v_net, 0)
      WHERE userID = NEW.userID;
    END IF;
  END IF;
END $$
DELIMITER ;


