package main

import "github.com/gin-gonic/gin"

func main() {
	r := gin.Default()
	r.GET("/healthz", func(c *gin.Context) { c.String(200, "ok") })
	r.Run()
}
