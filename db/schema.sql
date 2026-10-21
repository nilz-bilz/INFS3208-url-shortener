CREATE TABLE IF NOT EXISTS users (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  username      VARCHAR(50)  NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS links (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  code        VARCHAR(16)   NOT NULL UNIQUE,
  url         VARCHAR(2048) NOT NULL,
  user_id     INT           NOT NULL,
  click_count INT           NOT NULL DEFAULT 0,
  created_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  INDEX idx_links_user (user_id)
);

CREATE TABLE IF NOT EXISTS clicks (
  id         BIGINT AUTO_INCREMENT PRIMARY KEY,
  link_id    INT          NOT NULL,
  clicked_at DATETIME     NOT NULL,
  referrer   VARCHAR(255) NULL,
  user_agent VARCHAR(255) NULL,
  FOREIGN KEY (link_id) REFERENCES links(id) ON DELETE CASCADE,
  INDEX idx_clicks_link_time (link_id, clicked_at)
);
