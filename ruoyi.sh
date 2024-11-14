#!/bin/bash

# 颜色变量
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 默认端口配置
RUOYI_PORT=8080
MYSQL_PORT=3306

# 服务状态检查函数
check_services_status() {
    echo -e "\n${GREEN}=== 服务状态检查 ===${NC}"
    
    echo -e "\n${YELLOW}MariaDB状态：${NC}"
    systemctl status mariadb | grep "Active:"
    
    echo -e "\n${YELLOW}若依项目状态：${NC}"
    if [ -f "/opt/RuoYi/ruoyi-admin/target/ruoyi.pid" ]; then
        pid=$(cat /opt/RuoYi/ruoyi-admin/target/ruoyi.pid)
        if ps -p $pid > /dev/null; then
            echo "运行中 (PID: $pid)"
            # 获取该进程使用的所有端口
            JAVA_PORTS=$(netstat -nltp 2>/dev/null | grep "$pid/java" | awk '{print $4}' | awk -F: '{print $NF}')
        else
            echo "未运行"
        fi
    else
        echo "未运行"
    fi
    
    echo -e "\n${YELLOW}端口监听状态：${NC}"
    echo "TCP端口："
    if [ -n "$pid" ]; then
        # 显示Java进程的所有端口
        netstat -nltp | grep -E "(${pid}/java|:$MYSQL_PORT)"
    else
        # 如果Java进程未运行，只显示MySQL端口
        netstat -nltp | grep ":$MYSQL_PORT"
    fi
    
    echo -e "\n${YELLOW}Java进程状态：${NC}"
    ps aux | grep -E "[j]ava.*ruoyi-admin.jar" || echo "无运行中的Java进程"
}

# 配置端口函数
configure_ports() {
    echo -e "\n${GREEN}=== 端口配置 ===${NC}"
    
    echo "1. 修改若依项目端口"
    echo "2. 修改MySQL端口"
    echo "0. 返回"
    
    read -p "请选择要修改的端口 (0-2): " port_choice
    
    case $port_choice in
        1)
            read -p "请输入若依项目端口 (默认8080): " new_ruoyi_port
            RUOYI_PORT=${new_ruoyi_port:-8080}
            
            # 检查端口是否被占用
            if lsof -i:$RUOYI_PORT > /dev/null 2>&1; then
                echo -e "${RED}端口 $RUOYI_PORT 已被占用！${NC}"
                return 1
            fi
            
            # 更新应用配置文件
            if [ -f "/opt/RuoYi/ruoyi-admin/src/main/resources/application.yml" ]; then
                sed -i "s/port: [0-9]*/port: $RUOYI_PORT/" /opt/RuoYi/ruoyi-admin/src/main/resources/application.yml
                echo -e "${GREEN}若依项目端口已更新为: $RUOYI_PORT${NC}"
                
                # 重新编译和启动服务
                cd /opt/RuoYi
                mvn clean package -DskipTests
                start_services
            else
                echo -e "${RED}配置文件不存在！${NC}"
                return 1
            fi
            ;;
            
        2)
            read -p "请输入MySQL端口 (默认3306): " new_mysql_port
            MYSQL_PORT=${new_mysql_port:-3306}
            
            # 更新数据库配置文件
            if [ -f "/opt/RuoYi/ruoyi-admin/src/main/resources/application-druid.yml" ]; then
                sed -i "s/:3306/:$MYSQL_PORT/" /opt/RuoYi/ruoyi-admin/src/main/resources/application-druid.yml
                echo -e "${GREEN}MySQL端口已更新为: $MYSQL_PORT${NC}"
                
                # 先停止应用服务
                if [ -f "/opt/RuoYi/ruoyi-admin/target/ruoyi.pid" ]; then
                    pid=$(cat /opt/RuoYi/ruoyi-admin/target/ruoyi.pid)
                    kill -9 $pid 2>/dev/null
                    rm -f /opt/RuoYi/ruoyi-admin/target/ruoyi.pid
                fi
                
                # 重启 MySQL
                echo -e "${YELLOW}正在重启 MySQL 服务...${NC}"
                systemctl restart mariadb
                sleep 5  # 等待 MySQL 完全启动
                
                # 重新编译和启动应用
                cd /opt/RuoYi
                mvn clean package -DskipTests
                start_services
            else
                echo -e "${RED}配置文件不存在！${NC}"
                return 1
            fi
            ;;
            
        0)
            return 0
            ;;
            
        *)
            echo -e "${RED}无效的选择${NC}"
            return 1
            ;;
    esac
}

# 安装并初始化服务
install_services() {
    echo -e "\n${GREEN}开始安装若依系统...${NC}"
    
    # 安装必要的包
    apt update
    apt install -y default-jdk maven mariadb-server wget unzip git
    
    # 创建工作目录
    mkdir -p /opt/RuoYi
    cd /opt/RuoYi
    
    # 下载若依项目源码
    echo -e "${YELLOW}下载若依项目源码...${NC}"
    if [ ! -d "/opt/RuoYi/.git" ]; then
        rm -rf /opt/RuoYi/*  # 清理目录
        git clone https://gitee.com/y_project/RuoYi.git .
        if [ $? -ne 0 ]; then
            echo -e "${RED}源码下载失败！尝试使用备用下载方式...${NC}"
            # 备用下载方式：直接下载zip
            wget -O ruoyi.zip https://gitee.com/y_project/RuoYi/repository/archive/master.zip
            if [ $? -eq 0 ]; then
                unzip ruoyi.zip
                mv RuoYi-master/* .
                rm -rf RuoYi-master ruoyi.zip
            else
                echo -e "${RED}项目下载失败！${NC}"
                return 1
            fi
        fi
    fi
    
    # 检查源码是否存在
    if [ ! -f "pom.xml" ]; then
        echo -e "${RED}项目文件不完整！${NC}"
        return 1
    fi
    
    # 停止服务和清理进程
    systemctl stop mariadb
    sleep 2
    
    # 清理 MariaDB
    rm -rf /var/lib/mysql/*
    rm -rf /var/run/mysqld
    mkdir -p /var/run/mysqld
    chown mysql:mysql /var/run/mysqld
    chmod 777 /var/run/mysqld
    
    # 初始化 MariaDB
    mysql_install_db --user=mysql --datadir=/var/lib/mysql
    chown -R mysql:mysql /var/lib/mysql
    chmod -R 750 /var/lib/mysql
    
    # 启动 MariaDB
    systemctl start mariadb
    sleep 5
    
    # 初始化数据库
    mysql -u root << EOF
CREATE DATABASE IF NOT EXISTS ry DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'ruoyi'@'localhost' IDENTIFIED BY 'ruoyi123';
GRANT ALL PRIVILEGES ON ry.* TO 'ruoyi'@'localhost';
FLUSH PRIVILEGES;
EOF
    
    # 导入SQL文件
    for sql_file in sql/*.sql; do
        if [ -f "$sql_file" ]; then
            mysql -u root ry < "$sql_file"
        fi
    done
    
    # 确保配置目录存在
    mkdir -p ruoyi-admin/src/main/resources
    
    # 更新配文件
    CONFIG_FILE="/opt/RuoYi/ruoyi-admin/src/main/resources/application.yml"
    cat > "$CONFIG_FILE" << 'EOF'
# 项目相关配置
ruoyi:
  # 名称
  name: RuoYi
  # 版本
  version: 4.7.9
  # 版权年份
  copyrightYear: 2024
  # 实例演示开关
  demoEnabled: true
  # 文件路径
  profile: /opt/RuoYi/uploadPath
  # 获取ip地址开关
  addressEnabled: false

# 开发环境配置
server:
  # 服务器的HTTP端口，默认为8080
  port: 8080
  servlet:
    # 应用的访问路径
    context-path: /
  tomcat:
    # tomcat的URI编码
    uri-encoding: UTF-8
    # 连接数满后的排队数，默认为100
    accept-count: 1000
    threads:
      # tomcat最大线程数，默认为200
      max: 800
      # Tomcat启动初始化的线程数，默认值10
      min-spare: 100

# 用户配置
user:
  password:
    # 密码错误{maxRetryCount}次锁定10分钟
    maxRetryCount: 5

# Spring配置
spring:
  # 资源信息
  messages:
    # 国际化资源文件路径
    basename: i18n/messages
    encoding: UTF-8
  profiles:
    active: druid
  # 文件上传
  servlet:
    multipart:
      max-file-size: 10MB
      max-request-size: 20MB
  # 服务模块
  devtools:
    restart:
      enabled: true

# Shiro配置
shiro:
  user:
    # 登录地址
    loginUrl: /login
    # 权限认证失败地
    unauthorizedUrl: /unauth
    # 首页地址
    indexUrl: /index
    # 验证码开关
    captchaEnabled: true
    # 验证码类型 math 数组计算 char 字符验证
    captchaType: math
  cookie:
    # 设置Cookie的域名
    domain: 
    # 设置cookie的有效访问路径
    path: /
    # 设置HttpOnly属性
    httpOnly: true
    # 设置Cookie的过期时间，天为单位
    maxAge: 30
    # 设置密钥，保持唯一性
    cipherKey: zSyK5Kp6PZAAjlT+eeNMlg==
  session:
    # Session超时时间（默认30分钟）
    expireTime: 30
    # 同步session到数据库的周期（默认1分钟）
    dbSyncPeriod: 1
    # 相隔多久检查一次session的有效性，默认就是10分钟
    validationInterval: 10
    # 同一个用户最大会话数
    maxSession: -1
    # 踢出之前登录的/之后登录的用户，默认踢出之前登录的用户
    kickoutAfter: false

# 防止XSS攻击
xss:
  # 过滤开关
  enabled: true
  # 排除链接（多个用逗号分隔）
  excludes: /system/notice
  # 匹配链接
  urlPatterns: /system/*,/monitor/*,/tool/*

# token配置
token:
  # 令牌自定义标识
  header: Authorization
  # 令牌密钥
  secret: abcdefghijklmnopqrstuvwxyz
  # 令牌有效期（默认30钟）
  expireTime: 30

# MyBatis配置
mybatis:
  # 搜索指定包别名
  typeAliasesPackage: com.ruoyi.**.domain
  # 配置mapper的扫描，找到所有的mapper.xml映射文件
  mapperLocations: classpath*:mapper/**/*Mapper.xml
  # 加载全局的配置文件
  configLocation: classpath:mybatis/mybatis-config.xml

# PageHelper分页插件
pagehelper:
  helperDialect: mysql
  supportMethodsArguments: true
  params: count=countSql

# Swagger配置
swagger:
  # 是否开启swagger
  enabled: true
  # 请求前缀
  pathMapping: /dev-api
EOF

    # 创建数据库配置文件
    DRUID_CONFIG_FILE="/opt/RuoYi/ruoyi-admin/src/main/resources/application-druid.yml"
    cat > "$DRUID_CONFIG_FILE" << 'EOF'
# 数据源配置
spring:
    datasource:
        type: com.alibaba.druid.pool.DruidDataSource
        driverClassName: com.mysql.cj.jdbc.Driver
        druid:
            # 主库数据源
            master:
                url: jdbc:mysql://localhost:3306/ry?useUnicode=true&characterEncoding=utf8&zeroDateTimeBehavior=convertToNull&useSSL=true&serverTimezone=GMT%2B8
                username: ruoyi
                password: ruoyi123
            # 从库数据源
            slave:
                # 从数据源开关/默认关闭
                enabled: false
                url: 
                username: 
                password: 
            # 初始连接数
            initialSize: 5
            # 最小连接池数量
            minIdle: 10
            # 最大连接池数量
            maxActive: 20
            # 配置获取连接等待超时的时间
            maxWait: 60000
            # 配置连接超时时间
            connectTimeout: 30000
            # 配置网络超时时间
            socketTimeout: 60000
            # 配置间隔多久才进行一次检测，检测需要关闭的空闲连接，单位是毫秒
            timeBetweenEvictionRunsMillis: 60000
            # 配置一个连接在池中最小生存的时间，单位是毫秒
            minEvictableIdleTimeMillis: 300000
            # 配置一个连接在池中最大生存的时间，单位是毫秒
            maxEvictableIdleTimeMillis: 900000
            # 配置检测连接是否有效
            validationQuery: SELECT 1 FROM DUAL
            testWhileIdle: true
            testOnBorrow: false
            testOnReturn: false
            webStatFilter:
                enabled: true
            statViewServlet:
                enabled: true
                # 设置白名单，不填则允许所有访问
                allow:
                url-pattern: /druid/*
                # 控制台管理用户名和密码
                login-username: ruoyi
                login-password: 123456
            filter:
                stat:
                    enabled: true
                    # 慢SQL记录
                    log-slow-sql: true
                    slow-sql-millis: 1000
                    merge-sql: true
                wall:
                    config:
                        multi-statement-allow: true
EOF

    # 确保国际化配置目录存在
    echo -e "${YELLOW}配置国际化资源...${NC}"
    mkdir -p /opt/RuoYi/ruoyi-admin/src/main/resources/i18n
    
    # 创建中文消息配置文件
    cat > "/opt/RuoYi/ruoyi-admin/src/main/resources/i18n/messages.properties" << 'EOF'
#错误消息
not.null=* 必须填写
user.jcaptcha.error=验证码错误
user.jcaptcha.expire=验证码已失效
user.not.exists=用户不存在/密码错误
user.password.not.match=用户不存在/密码错误
user.password.retry.limit.count=密码输入错误{0}次
user.password.retry.limit.exceed=密码输入错误{0}次，帐户锁定{1}分钟
user.password.delete=对不起，您的账号已被删除
user.blocked=用户已封禁，请联系管理员
user.logout.success=退出成功
length.not.valid=长度必须在{min}到{max}个字符之间
user.username.not.valid=* 2到20个汉字、字母、数字或下划线组成，且必须以非数字开头
user.password.not.valid=* 5-50个字符
user.email.not.valid=邮箱格式错误
user.mobile.phone.number.not.valid=手机号格式错误
user.login.success=登录成功
user.register.success=注册成功
user.notfound=请重新登录
user.forcelogout=管理员强制退出，请重新登录
user.unknown.error=未知错误，请重新登录
EOF

    # 创建中文繁体消息配置文件
    cat > "/opt/RuoYi/ruoyi-admin/src/main/resources/i18n/messages_zh_TW.properties" << 'EOF'
#错误消息
not.null=* 必須填寫
user.jcaptcha.error=驗證碼錯誤
user.jcaptcha.expire=驗證碼已失效
user.not.exists=用戶不存在/密碼錯誤
user.password.not.match=用戶不存在/密碼錯誤
user.password.retry.limit.count=密碼輸入錯誤{0}次
user.password.retry.limit.exceed=密碼輸入錯誤{0}次，帳戶鎖定{1}分鐘
user.password.delete=對不起，您的賬號已被刪除
user.blocked=用戶已封禁，請聯繫管理員
user.logout.success=退出成功
length.not.valid=長度必須在{min}到{max}個字符之間
user.username.not.valid=* 2到20個漢字、字母、數字或下劃線組成，且必須以非數字開頭
user.password.not.valid=* 5-50個字符
user.email.not.valid=郵箱格式錯誤
user.mobile.phone.number.not.valid=手機號格式錯
user.login.success=登錄成功
user.register.success=註冊成功
user.notfound=請重新登錄
user.forcelogout=管理員強制退出，請重新登錄
user.unknown.error=未知錯誤，請重新登錄
EOF

    # 创建英文消息配置文件
    cat > "/opt/RuoYi/ruoyi-admin/src/main/resources/i18n/messages_en_US.properties" << 'EOF'
#Error message
not.null=* Required fill in
user.jcaptcha.error=Verification code error
user.jcaptcha.expire=Verification code invalid
user.not.exists=User does not exist/Password error
user.password.not.match=User does not exist/Password error
user.password.retry.limit.count=Password input error {0} times
user.password.retry.limit.exceed=Password input error {0} times, account locked for {1} minutes
user.password.delete=Sorry, your account has been deleted
user.blocked=User has been blocked, please contact administrator
user.logout.success=Logout successful
length.not.valid=Length must be between {min} and {max} characters
user.username.not.valid=* 2 to 20 Chinese characters, letters, numbers or underscores, and must start with a non-digit
user.password.not.valid=* 5-50 characters
user.email.not.valid=Incorrect email format
user.mobile.phone.number.not.valid=Incorrect phone number format
user.login.success=Login successful
user.register.success=Registration successful
user.notfound=Please login again
user.forcelogout=Administrator forced logout, please login again
user.unknown.error=Unknown error, please login again
EOF

    # 编译项目
    echo -e "${YELLOW}编译项目...${NC}"
    cd /opt/RuoYi
    mvn clean package -DskipTests
    
    # 启动服务
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}编译成功，准备启动服务...${NC}"
        start_services
    else
        echo -e "${RED}编译失败！${NC}"
        return 1
    fi
}

# 查看服务日志函数
view_service_logs() {
    echo -e "\n${GREEN}=== 服务日志查看 ===${NC}"
    echo -e "\n${YELLOW}可用的日志查看命令：${NC}"
    
    echo -e "\n${GREEN}1. Nginx错误日志：${NC}"
    echo "tail -n 200 /var/log/nginx/error.log"
    
    echo -e "\n${GREEN}2. Nginx访问日志：${NC}"
    echo "tail -n 200 /var/log/nginx/access.log"
    
    echo -e "\n${GREEN}3. MariaDB日志：${NC}"
    echo "tail -n 200 /var/log/mysql/error.log"
    
    echo -e "\n${GREEN}4. 若依项目日志：${NC}"
    echo "tail -n 200 /opt/RuoYi/ruoyi-admin/target/ruoyi.log"
    
    echo -e "\n${YELLOW}请复制相应命令在终端中执行查看日志${NC}"
}

# 停止服务函数改进
stop_services() {
    echo -e "${YELLOW}正在停止服务...${NC}"
    
    # 停止 MariaDB
    systemctl stop mariadb
    
    # 停止若依服务
    if [ -f "/opt/RuoYi/ruoyi-admin/target/ruoyi.pid" ]; then
        pid=$(cat /opt/RuoYi/ruoyi-admin/target/ruoyi.pid)
        if [ -n "$pid" ]; then
            kill -9 $pid 2>/dev/null
            rm -f /opt/RuoYi/ruoyi-admin/target/ruoyi.pid
        fi
    fi
    
    # 查找并杀所有相关进程
    echo -e "${YELLOW}清理残留进程...${NC}"
    for port in $RUOYI_PORT $MYSQL_PORT; do
        pid=$(lsof -t -i:$port 2>/dev/null)
        if [ -n "$pid" ]; then
            echo "killing process on port $port (PID: $pid)"
            kill -9 $pid 2>/dev/null
        fi
    done
    
    # 等待进程完全停止
    sleep 3
    
    echo -e "${GREEN}所有服务已停止${NC}"
}

# 启动服务函数改进
start_services() {
    echo -e "${YELLOW}启动服务...${NC}"
    
    # 先确保服务已停止
    stop_services
    
    # 启动 MariaDB
    echo -e "${YELLOW}启动 MariaDB...${NC}"
    systemctl start mariadb
    sleep 5  # 等待数据库完全启动
    
    # 检查数据库是否正常运行
    if ! systemctl is-active --quiet mariadb; then
        echo -e "${RED}MariaDB 启动失败！${NC}"
        return 1
    fi
    
    # 检查目录
    if [ ! -d "/opt/RuoYi/ruoyi-admin/target" ]; then
        echo -e "${RED}目标目录不存在！${NC}"
        return 1
    fi
    
    cd /opt/RuoYi/ruoyi-admin/target/
    
    # 确保日志目录存在
    mkdir -p /opt/RuoYi/logs
    touch /opt/RuoYi/logs/sys-user.log
    
    # 启动若依服务
    echo -e "${YELLOW}启动若依服务...${NC}"
    nohup java -jar ruoyi-admin.jar > ruoyi.log 2>&1 & echo $! > ruoyi.pid
    
    # 等待服务启动
    echo -e "${YELLOW}等待服务启动...${NC}"
    tail -f ruoyi.log &
    tail_pid=$!
    
    for i in {1..60}; do
        if grep -q "Started RuoYiApplication" ruoyi.log; then
            kill $tail_pid
            echo -e "${GREEN}服务启动成功！${NC}"
            echo -e "${GREEN}访问地址: http://localhost:$RUOYI_PORT${NC}"
            return 0
        fi
        if grep -q "Application run failed" ruoyi.log || grep -q "Exception" ruoyi.log; then
            kill $tail_pid
            echo -e "${RED}服务启动失！${NC}"
            echo -e "${YELLOW}错误日志：${NC}"
            tail -n 50 ruoyi.log
            return 1
        fi
        sleep 1
    done
    
    kill $tail_pid
    echo -e "${RED}服务启动超时！${NC}"
    return 1
}

# 清理所有服务和文件
clean_all() {
    echo -e "${RED}警告：这将删除所有相关服务和文件！${NC}"
    read -p "确定要继续吗？(y/n) " confirm
    
    if [ "$confirm" = "y" ]; then
        stop_services
        
        # 卸载服务
        apt remove -y mariadb-server default-jdk maven
        apt autoremove -y
        
        # 删除文件
        rm -rf /opt/RuoYi
        rm -rf /var/lib/mysql
        
        echo -e "${GREEN}清理完成${NC}"
    fi
}

# 备份函数
backup_config() {
    echo -e "\n${GREEN}=== 备份配置 ===${NC}"
    
    # 创建备份目录
    BACKUP_DIR="/opt/RuoYi/backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # 备份配置文件
    cp -r /opt/RuoYi/ruoyi-admin/src/main/resources/* "$BACKUP_DIR/"
    
    # 备份数据库
    mysqldump -u root ry > "$BACKUP_DIR/ry.sql"
    
    # 创建备份信息文件
    echo "Backup created at: $(date)" > "$BACKUP_DIR/backup_info.txt"
    echo "RuoYi Port: $RUOYI_PORT" >> "$BACKUP_DIR/backup_info.txt"
    echo "MySQL Port: $MYSQL_PORT" >> "$BACKUP_DIR/backup_info.txt"
    
    echo -e "${GREEN}备份完成: $BACKUP_DIR${NC}"
}

# 恢复函数
restore_config() {
    echo -e "\n${GREEN}=== 恢复配置 ===${NC}"
    
    # 列出所有备份
    echo -e "${YELLOW}可用的备份:${NC}"
    ls -lt /opt/RuoYi/backup/
    
    read -p "请输入要恢复的备份目录名称: " backup_name
    RESTORE_DIR="/opt/RuoYi/backup/$backup_name"
    
    if [ ! -d "$RESTORE_DIR" ]; then
        echo -e "${RED}备份目录不存在！${NC}"
        return 1
    fi
    
    # 停止服务
    stop_services
    
    # 恢复配置文件
    cp -r "$RESTORE_DIR"/* /opt/RuoYi/ruoyi-admin/src/main/resources/
    
    # 恢复据库
    mysql -u root ry < "$RESTORE_DIR/ry.sql"
    
    # 重新编译和启动服务
    cd /opt/RuoYi
    mvn clean package -DskipTests
    start_services
    
    echo -e "${GREEN}恢复完成${NC}"
}

show_help() {
    echo -e "\n${GREEN}=== 若依系统帮助信息 ===${NC}"
    echo -e "${YELLOW}默认账户信息：${NC}"
    echo "账号: admin"
    echo "密码: admin123"
    echo -e "\n${YELLOW}访问地址：${NC}"
    echo "前台地址: http://localhost:${RUOYI_PORT}"
    echo "后台地址: http://localhost:${RUOYI_PORT}/login"
    echo -e "\n${YELLOW}数据库信息：${NC}"
    echo "数据库名: ry"
    echo "用户名: ruoyi"
    echo "密码: ruoyi123"
    echo "端口: ${MYSQL_PORT}"
}

deploy_jar() {
    echo -e "\n${GREEN}=== 部署已有JAR包 ===${NC}"
    
    # 创建部署目录
    mkdir -p /opt/RuoYi/ruoyi-admin/target
    
    # 提示用户复制JAR包
    echo -e "${YELLOW}请将您的JAR包复制到以下位置：${NC}"
    echo "/opt/RuoYi/ruoyi-admin/target/ruoyi-admin.jar"
    echo -e "\n${YELLOW}复制命令示例：${NC}"
    echo "cp /path/to/your/ruoyi-admin.jar /opt/RuoYi/ruoyi-admin/target/"
    
    # 等待用户确认
    read -p "JAR包已经复制到指定位置了吗？(y/n) " confirm
    if [ "$confirm" != "y" ]; then
        echo -e "${RED}操作取消${NC}"
        return 1
    fi
    
    # 检查JAR包是否存在
    if [ ! -f "/opt/RuoYi/ruoyi-admin/target/ruoyi-admin.jar" ]; then
        echo -e "${RED}错误：JAR包不存在！${NC}"
        return 1
    fi
    
    # 启动服务
    echo -e "${YELLOW}正在启动服务...${NC}"
    start_services
}

show_jar_deploy_guide() {
    echo -e "\n${GREEN}=== JAR包部署说明 ===${NC}"
    echo -e "\n${YELLOW}1. 准备工作：${NC}"
    echo "- 确保服务器已安装 JDK 1.8+"
    echo "- 准备好已编译的 ruoyi-admin.jar 文件"
    
    echo -e "\n${YELLOW}2. 部署步骤：${NC}"
    echo "1) 将JAR包复制到服务器"
    echo "   scp ruoyi-admin.jar user@server:/tmp/"
    
    echo -e "\n2) 创建部署目录"
    echo "   mkdir -p /opt/RuoYi/ruoyi-admin/target"
    
    echo -e "\n3) 移动JAR包到部署目录"
    echo "   mv /tmp/ruoyi-admin.jar /opt/RuoYi/ruoyi-admin/target/"
    
    echo -e "\n4) 使用此脚本部署"
    echo "   - 选择选项12：部署JAR包"
    echo "   或"
    echo "   - 选择选项4：启动服务"
    
    echo -e "\n${YELLOW}3. 常用操作：${NC}"
    echo "- 启动服务：选项4"
    echo "- 停止服务：选项5"
    echo "- 查看日志：选项7"
    echo "- 修改端口：选项2"
    
    echo -e "\n${YELLOW}4. 注意事项：${NC}"
    echo "- 确保JAR包名称为 ruoyi-admin.jar"
    echo "- 确保有足够系统内存"
    echo "- 建议先停止旧服务再部署新包"
}

# Docker 相关函数
generate_dockerfile() {
    echo -e "\n${GREEN}=== 生成 Docker 文件 ===${NC}"
    
    DOCKER_DIR="/opt/RuoYi/docker"
    mkdir -p "${DOCKER_DIR}"
    
    # 创建数据库 Dockerfile
    mkdir -p "${DOCKER_DIR}/mysql"
    cat > "${DOCKER_DIR}/mysql/Dockerfile" << 'EOF'
FROM mariadb:10.6

ENV TZ=Asia/Shanghai

# 添加自定义配置
COPY my.cnf /etc/mysql/conf.d/my.cnf
COPY init.sql /docker-entrypoint-initdb.d/

CMD ["mysqld"]
EOF

    # 创建 MariaDB 配置文件
    cat > "${DOCKER_DIR}/mysql/my.cnf" << 'EOF'
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_general_ci
init_connect='SET NAMES utf8mb4'
skip-character-set-client-handshake=true
max_connections=1000
innodb_buffer_pool_size=512M
innodb_log_file_size=256M
innodb_log_buffer_size=64M
innodb_write_io_threads=8
innodb_read_io_threads=8
innodb_flush_log_at_trx_commit=2
EOF

    # 导出当前数据库
    echo -e "${YELLOW}导出当前数据库...${NC}"
    if systemctl is-active --quiet mariadb; then
        mysqldump -u root ry > "${DOCKER_DIR}/mysql/init.sql"
        echo -e "${GREEN}数据库导出成功：${DOCKER_DIR}/mysql/init.sql${NC}"
    else
        echo -e "${RED}警告：数据库未运行，无法导出数据${NC}"
        return 1
    fi

    # 创建 docker-compose.yml
    cat > "${DOCKER_DIR}/docker-compose.yml" << EOF
version: '3.8'

services:
  ruoyi-mysql:
    build: 
      context: ./mysql
    container_name: ruoyi-mysql
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: ry
      MYSQL_USER: ruoyi
      MYSQL_PASSWORD: ruoyi123
    volumes:
      - mysql_data:/var/lib/mysql
    ports:
      - "3306:3306"
    networks:
      - ruoyi-net
    command: 
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_general_ci
      - --default-authentication-plugin=mysql_native_password
    healthcheck:
      test: ["CMD", "mysql", "-h", "localhost", "-u", "root", "-proot", "-e", "SELECT 1"]
      interval: 5s
      timeout: 3s
      retries: 10

  ruoyi-app:
    build: 
      context: ./app
    container_name: ruoyi-app
    depends_on:
      ruoyi-mysql:
        condition: service_healthy
    ports:
      - "8888:8888"
    volumes:
      - ./logs:/app/logs
      - ./uploadPath:/app/uploadPath
    environment:
      - SPRING_PROFILES_ACTIVE=druid
    networks:
      - ruoyi-net
    restart: unless-stopped

networks:
  ruoyi-net:
    driver: bridge

volumes:
  mysql_data:
    driver: local
EOF

    # 创建应用 Dockerfile
    mkdir -p "${DOCKER_DIR}/app"
    cat > "${DOCKER_DIR}/app/Dockerfile" << 'EOF'
FROM openjdk:8-jdk

WORKDIR /app

# 创建配置文件目录
RUN mkdir -p /app/config

# 复制应用和配置文件
COPY ruoyi-admin.jar ./
COPY config/* ./config/

ENV TZ=Asia/Shanghai
ENV JAVA_OPTS="-Xms512m -Xmx1024m -Djava.security.egd=file:/dev/./urandom"

EXPOSE 8888

# 修改启动命令，指定配置文件位置
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar ruoyi-admin.jar --spring.config.location=file:/app/config/"]
EOF

    # 创建配置文件目录
    mkdir -p "${DOCKER_DIR}/app/config"
    
    # 复制并修改配置文件
    if [ -f "/opt/RuoYi/ruoyi-admin/src/main/resources/application.yml" ]; then
        cp /opt/RuoYi/ruoyi-admin/src/main/resources/application*.yml "${DOCKER_DIR}/app/config/"
        
        # 修改数据库连接配置
        sed -i 's/localhost/ruoyi-mysql/g' "${DOCKER_DIR}/app/config/application-druid.yml"
        
        # 确保 druid 配置存在
        cat > "${DOCKER_DIR}/app/config/application-druid.yml" << 'EOF'
# 数据源配置
spring:
    datasource:
        type: com.alibaba.druid.pool.DruidDataSource
        driverClassName: com.mysql.cj.jdbc.Driver
        druid:
            # 主库数据源
            master:
                url: jdbc:mysql://ruoyi-mysql:3306/ry?useUnicode=true&characterEncoding=utf8&zeroDateTimeBehavior=convertToNull&useSSL=true&serverTimezone=GMT%2B8
                username: root
                password: root
            # 从库数据源
            slave:
                # 从数据源开关/默认关闭
                enabled: false
                url: 
                username: 
                password: 
            # 初始连接数
            initialSize: 5
            # 最小连接池数量
            minIdle: 10
            # 最大连接池数量
            maxActive: 20
            # 配置获取连接等待超时的时间
            maxWait: 60000
            # 配置连接超时时间
            connectTimeout: 30000
            # 配置网络超时时间
            socketTimeout: 60000
            # 配置间隔多久才进行一次检测，检测需要关闭的空闲连接，单位是毫秒
            timeBetweenEvictionRunsMillis: 60000
            # 配置一个连接在池中最小生存的时间，单位是毫秒
            minEvictableIdleTimeMillis: 300000
            # 配置一个连接在池中最大生存的时间，单位是毫秒
            maxEvictableIdleTimeMillis: 900000
            # 配置检测连接是否有效
            validationQuery: SELECT 1 FROM DUAL
            testWhileIdle: true
            testOnBorrow: false
            testOnReturn: false
EOF
        
        echo -e "${GREEN}配置文件已更新${NC}"
    else
        echo -e "${RED}警告：配置文件不存在${NC}"
        return 1
    fi

    echo -e "${GREEN}docker-compose.yml 已生成：${DOCKER_DIR}/docker-compose.yml${NC}"
    echo -e "\n${GREEN}所有 Docker 文件生成完成！${NC}"
    echo -e "${YELLOW}文件位置：${DOCKER_DIR}${NC}"
}

build_mysql_image() {
    echo -e "\n${GREEN}=== 构建数据库镜像 ===${NC}"
    
    DOCKER_DIR="/opt/RuoYi/docker"
    
    if [ ! -f "${DOCKER_DIR}/mysql/Dockerfile" ]; then
        echo -e "${RED}Dockerfile不存在，请先生成${NC}"
        return 1
    fi

    cd "${DOCKER_DIR}"
    # 强制重新构建
    docker-compose build --no-cache ruoyi-mysql
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}数据库镜像构建成功${NC}"
    else
        echo -e "${RED}数据库镜像构建失败${NC}"
        return 1
    fi
}

build_app_image() {
    echo -e "\n${GREEN}=== 构建应用镜像 ===${NC}"
    
    DOCKER_DIR="/opt/RuoYi/docker"
    
    if [ ! -f "${DOCKER_DIR}/app/Dockerfile" ]; then
        echo -e "${RED}Dockerfile不存在，请先生成${NC}"
        return 1
    fi

    cd "${DOCKER_DIR}"
    # 强制重新构建
    docker-compose build --no-cache ruoyi-app
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}应用镜像构建成功${NC}"
    else
        echo -e "${RED}应用镜像构建失败${NC}"
        return 1
    fi
}

build_images() {
    echo -e "\n${GREEN}=== 构建所有镜像 ===${NC}"
    
    DOCKER_DIR="/opt/RuoYi/docker"
    
    if [ ! -f "${DOCKER_DIR}/docker-compose.yml" ]; then
        echo -e "${RED}docker-compose.yml不存在，请先生成${NC}"
        return 1
    fi

    cd "${DOCKER_DIR}"
    
    echo -e "${YELLOW}开始构建所有镜像...${NC}"
    # 强制重新构建所有镜像
    docker-compose build --no-cache
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}所有镜像构建成功${NC}"
    else
        echo -e "${RED}镜像构建失败${NC}"
        return 1
    fi
}

deploy_docker() {
    echo -e "\n${GREEN}=== 部署 Docker 容器 ===${NC}"
    
    DOCKER_DIR="/opt/RuoYi/docker"
    cd "${DOCKER_DIR}"
    
    # 检查 docker-compose.yml 是否存在
    if [ ! -f "docker-compose.yml" ]; then
        echo -e "${RED}docker-compose.yml不存在，请先生成${NC}"
        return 1
    fi
    
    # 检查镜像是否存在（修正镜像名称检查）
    if ! docker images | grep -q "docker-ruoyi-mysql\|docker_ruoyi-mysql"; then
        echo -e "${RED}数据库镜像不存在，是否现在构建？(y/n)${NC}"
        read -p "" build_choice
        if [ "$build_choice" = "y" ]; then
            build_mysql_image
        else
            return 1
        fi
    fi
    
    if ! docker images | grep -q "docker-ruoyi-app\|docker_ruoyi-app"; then
        echo -e "${RED}应用镜像不存在，是否现在构建？(y/n)${NC}"
        read -p "" build_choice
        if [ "$build_choice" = "y" ]; then
            build_app_image
        else
            return 1
        fi
    fi

    # 清理现有容器和卷
    echo -e "${YELLOW}清理现有容器和数据...${NC}"
    docker-compose down -v

    # 创建必要的目录和权限
    mkdir -p logs uploadPath
    chmod -R 777 logs uploadPath

    # 启动容器
    echo -e "${YELLOW}启动 Docker 容器...${NC}"
    docker-compose up -d

    # 等待服务启动
    echo -e "${YELLOW}等待服务启动...${NC}"
    
    # 等待数据库启动
    echo -e "${YELLOW}等待数据库启动...${NC}"
    for i in {1..60}; do
        if docker-compose exec ruoyi-mysql mysql -uroot -proot -e "SELECT 1" >/dev/null 2>&1; then
            echo -e "${GREEN}数据库启动成功！${NC}"
            break
        fi
        echo -n "."
        sleep 2
        if [ $i -eq 60 ]; then
            echo -e "${RED}数据库启动超时！${NC}"
            docker-compose logs ruoyi-mysql
            return 1
        fi
    done

    # 等待应用启动
    CURRENT_PORT=$(grep "port:" "${DOCKER_DIR}/app/config/application.yml" | awk '{print $2}')
    CURRENT_PORT=${CURRENT_PORT:-8888}
    
    echo -e "${YELLOW}等待应用启动...${NC}"
    for i in {1..60}; do
        if curl -s "http://localhost:${CURRENT_PORT}" >/dev/null; then
            echo -e "${GREEN}服务启动成功！${NC}"
            echo -e "${GREEN}访问地址: http://localhost:${CURRENT_PORT}${NC}"
            return 0
        fi
        echo -n "."
        sleep 2
    done

    echo -e "\n${RED}服务启动超时，请检查日志${NC}"
    docker-compose logs
}

stop_docker() {
    echo -e "\n${GREEN}=== 停止 Docker 容器 ===${NC}"
    
    cd "/opt/RuoYi/docker"
    docker-compose down
    echo -e "${GREEN}Docker 容器已停止${NC}"
}

check_docker_status() {
    echo -e "\n${GREEN}=== Docker 容器状态 ===${NC}"
    
    cd "/opt/RuoYi/docker"
    echo -e "\n${YELLOW}容器状态：${NC}"
    docker-compose ps
    
    echo -e "\n${YELLOW}容器资源使用：${NC}"
    docker stats --no-stream
}

view_docker_logs() {
    while true; do
        echo -e "\n${GREEN}=== Docker 日志查看 ===${NC}"
        echo "1. 查看应用日志"
        echo "2. 查看数据库日志"
        echo "3. 查看所有日志"
        echo "0. 返回"
        
        read -p "请选择 (0-3): " log_choice
        case $log_choice in
            1) 
                cd "/opt/RuoYi/docker"
                docker-compose logs -f ruoyi-app
                ;;
            2)
                cd "/opt/RuoYi/docker"
                docker-compose logs -f ruoyi-mysql
                ;;
            3)
                cd "/opt/RuoYi/docker"
                docker-compose logs -f
                ;;
            0) break ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
    done
}

docker_manage() {
    while true; do
        echo -e "\n${GREEN}=== Docker 管理 ===${NC}"
        
        # 检查 Docker 环境
        if ! command -v docker >/dev/null 2>&1; then
            echo -e "${YELLOW}Docker未安装，是否现在安装？(y/n)${NC}"
            read -p "" install_choice
            if [ "$install_choice" = "y" ]; then
                echo -e "${YELLOW}正在安装 Docker...${NC}"
                apt update
                apt install -y docker.io docker-compose
                systemctl enable docker
                systemctl start docker
            else
                return 1
            fi
        fi

        echo "1. 生成 Docker 文件"
        echo "2. 构建所有镜像"
        echo "3. 构建数据库镜像"
        echo "4. 构建应用镜像"
        echo "5. 部署 Docker 容器"
        echo "6. 停止 Docker 容器"
        echo "7. 查看容器状态"
        echo "8. 查看容器日志"
        echo "0. 返回主菜单"
        
        read -p "请选择操作 (0-8): " docker_choice
        
        case $docker_choice in
            1) generate_dockerfile ;;
            2) build_images ;;
            3) build_mysql_image ;;
            4) build_app_image ;;
            5) deploy_docker ;;
            6) stop_docker ;;
            7) check_docker_status ;;
            8) view_docker_logs ;;
            0) break ;;
            *) echo -e "${RED}无效的选择${NC}" ;;
        esac
    done
}

# 在主菜单中添加新选项
while true; do
    echo -e "\n${GREEN}=== 若依系统管理脚本 ===${NC}"
    echo "1. 查看服务状态"
    echo "2. 配置服务端口"
    echo "3. 安装并初始化服务"
    echo "4. 启动所有服务"
    echo "5. 停止所有服务"
    echo "6. 清理所有服务和文件"
    echo "7. 查看服务日志"
    echo "8. 备份当前配置"
    echo "9. 恢复历史配置"
    echo "10. 查看帮助信息"
    echo "11. 查看部署说明"
    echo "12. 部署JAR包"
    echo "13. 查看JAR包部署说明"
    echo "14. Docker 管理"
    echo "0. 退出"
    
    read -p "请选择操作 (0-14): " choice
    
    case $choice in
        1) check_services_status ;;
        2) configure_ports ;;
        3) install_services ;;
        4) start_services ;;
        5) stop_services ;;
        6) clean_all ;;
        7) view_service_logs ;;
        8) backup_config ;;
        9) restore_config ;;
        10) show_help ;;
        11) show_deploy_guide ;;
        12) deploy_jar ;;
        13) show_jar_deploy_guide ;;
        14) docker_manage ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效的选择${NC}" ;;
    esac
done
