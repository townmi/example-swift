package middlewares

import (
	"time"

	sugar "../sugar" //sugar
	"github.com/gin-gonic/gin"
)

// Logger middle
func Logger() gin.HandlerFunc {
	return func(c *gin.Context) {
		// 开始时间
		start := time.Now()
		// 处理请求
		c.Next()
		// 结束时间
		end := time.Now()
		//执行时间
		latency := end.Sub(start)
		path := c.Request.URL.Path
		clientIP := c.ClientIP()
		method := c.Request.Method
		statusCode := c.Writer.Status()

		log := sugar.GetLogger()

		log.Infof("%v %v %v %v %v\n",
			method,
			statusCode,
			path,
			clientIP,
			latency,
		)
	}
}
