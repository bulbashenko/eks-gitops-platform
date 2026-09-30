// Package queue wraps SQS for publishing and consuming order messages.
package queue

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
)

type OrderMessage struct {
	ID        string    `json:"id"`
	Item      string    `json:"item"`
	Qty       int       `json:"qty"`
	CreatedAt time.Time `json:"created_at"`
}

type Message struct {
	Order         OrderMessage
	ReceiptHandle string
	// Raw is kept so malformed messages can be logged; they are left for the DLQ.
	Raw string
	Err error
}

type Queue struct {
	client *sqs.Client
	url    string
}

func New(client *sqs.Client, url string) *Queue {
	return &Queue{client: client, url: url}
}

func (q *Queue) Publish(ctx context.Context, m OrderMessage) error {
	body, err := json.Marshal(m)
	if err != nil {
		return err
	}
	_, err = q.client.SendMessage(ctx, &sqs.SendMessageInput{
		QueueUrl:    aws.String(q.url),
		MessageBody: aws.String(string(body)),
	})
	if err != nil {
		return fmt.Errorf("send message: %w", err)
	}
	return nil
}

// Receive long-polls for up to 10 messages.
func (q *Queue) Receive(ctx context.Context) ([]Message, error) {
	out, err := q.client.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
		QueueUrl:            aws.String(q.url),
		MaxNumberOfMessages: 10,
		WaitTimeSeconds:     20,
	})
	if err != nil {
		return nil, fmt.Errorf("receive messages: %w", err)
	}
	msgs := make([]Message, 0, len(out.Messages))
	for _, m := range out.Messages {
		msg := Message{ReceiptHandle: aws.ToString(m.ReceiptHandle), Raw: aws.ToString(m.Body)}
		msg.Err = json.Unmarshal([]byte(msg.Raw), &msg.Order)
		msgs = append(msgs, msg)
	}
	return msgs, nil
}

func (q *Queue) Delete(ctx context.Context, receiptHandle string) error {
	_, err := q.client.DeleteMessage(ctx, &sqs.DeleteMessageInput{
		QueueUrl:      aws.String(q.url),
		ReceiptHandle: aws.String(receiptHandle),
	})
	return err
}
